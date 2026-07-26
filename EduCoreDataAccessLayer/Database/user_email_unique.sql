-- ============================================================================
-- user_email_unique.sql
--
-- ONE definition of "is this email already taken?", enforced in the database and
-- reused by every proc that creates a login.
--
-- THE BUG THIS FIXES
-- Creating a school admin with an email held by a DEACTIVATED user failed with a
-- raw Postgres error instead of a message:
--     ERROR: duplicate key value violates unique constraint "uq_user_email"
-- because sp_school_manage checked `is_active = TRUE` (so it didn't see the
-- deactivated row and allowed the save) while uq_user_email (tenant_id, email)
-- covers EVERY row including deactivated and soft-deleted ones. The guard and
-- the constraint disagreed, so the guard passed and the INSERT blew up.
--
-- THE REAL INVARIANT
-- Login and password-reset both resolve a user by email with NO tenant filter:
--     core.sp_login_management : WHERE LOWER(u.email) = LOWER(p_email)
--                                 AND u.is_deleted = FALSE AND u.is_active = TRUE
--     core.sp_password_reset   : same predicate
-- So the rule the app actually depends on is:
--     an email identifies AT MOST ONE active, non-deleted user — GLOBALLY.
-- uq_user_email (tenant_id, email) was both too weak (two tenants could hold the
-- same email, making login ambiguous — it picks one via ORDER BY role_code) and
-- too strong (a deactivated user burned that email for its tenant forever).
--
-- Verified before running: 0 duplicate emails among active users, 0 soft-deleted
-- or deactivated users, 0 emails differing only by case/whitespace.
-- Re-runnable.
-- ============================================================================

-- 1) Replace the per-tenant constraint with the rule login actually needs.
--    Dropped rather than kept: it is what makes a deactivated user's email
--    unusable forever, which is the bug. Nothing looks up inactive/deleted users
--    by email (checked every proc), so allowing duplicates among them is safe.
ALTER TABLE core.users DROP CONSTRAINT IF EXISTS uq_user_email;

-- 2) Global, case- and whitespace-insensitive, and only over accounts that can
--    actually sign in — matching the login/reset predicate exactly.
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_email_active
    ON core.users (LOWER(TRIM(email)))
    WHERE is_active = TRUE AND is_deleted = FALSE;

-- 3) The single guard every proc calls, so the app-side check can never drift
--    from the index again. STABLE + SQL so it inlines.
--    p_exclude_user_id: the user being edited, who must not clash with themselves.
CREATE OR REPLACE FUNCTION core.fn_user_email_taken(
    p_email            character varying,
    p_exclude_user_id  integer DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM core.users
        WHERE LOWER(TRIM(email)) = LOWER(TRIM(p_email))
          AND is_active  = TRUE
          AND is_deleted = FALSE
          AND (p_exclude_user_id IS NULL OR user_id <> p_exclude_user_id)
    );
$$;

COMMENT ON FUNCTION core.fn_user_email_taken(character varying, integer) IS
    'TRUE when the email already belongs to an active, non-deleted login user (global, matching core.sp_login_management). Guard for every proc that creates or renames a login; backed by uq_user_email_active.';

-- 4) Cursor wrapper so the app can ask the same question BEFORE submit, without
--    services running raw SQL (everything goes through a proc via PgExec).
--    Used by SuperAdmin/Schools/CheckEmail for the wizard's live availability hint.
CREATE OR REPLACE PROCEDURE core.sp_user_email_check(
    IN p_email character varying,
    IN p_exclude_user_id integer DEFAULT NULL,
    INOUT p_result refcursor DEFAULT 'email_check_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    OPEN p_result FOR
    SELECT core.fn_user_email_taken(p_email, p_exclude_user_id) AS is_taken;
END;
$procedure$;
