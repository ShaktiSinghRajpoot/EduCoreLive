-- ============================================================================
-- Retire the school "Delete" (soft delete) in favour of status = Closed.
--
-- THE PROBLEM IT CAUSED
-- Delete set core.schools.is_deleted = TRUE. But sp_school_list and the GET branch
-- of sp_school_manage both filter is_deleted = FALSE, so a deleted school became
-- completely unreachable:
--     * not in the school list
--     * cannot be opened in Edit
--     * therefore its status cannot be changed
--     * therefore it can never be Closed, and never Purged
-- Seven schools were stuck in exactly that state, one of them (SCH1 ABC Public
-- School) holding 10 students and 25 fee payments that nobody could see or remove.
--
-- WHY DELETE IS REDUNDANT NOW
-- status = Closed already blocks every login (see school_status_login_gate.sql),
-- and unlike a soft delete it is visible, reversible and auditable. Two mechanisms
-- meaning "this school is finished" only drift apart. The flow is now:
--     Active  ->  Closed  (reversible)  ->  Purge  (permanent, archived)
--
-- This migration brings the stuck schools back onto that one path: visible in the
-- list, blocked from login, editable, and purgeable if they really are finished.
-- No data is deleted.
-- Re-runnable.
-- ============================================================================

UPDATE core.schools s
SET is_deleted = FALSE,
    is_active  = TRUE,
    status_id  = (SELECT school_status_id FROM config.school_statuses
                  WHERE status_code = 'CLOSED' AND is_deleted = FALSE),
    deleted_by = NULL,
    deleted_at = NULL,
    updated_at = NOW()
WHERE s.is_deleted = TRUE;

-- After this, nothing should remain soft-deleted:
--   SELECT school_code, school_name FROM core.schools WHERE is_deleted;
