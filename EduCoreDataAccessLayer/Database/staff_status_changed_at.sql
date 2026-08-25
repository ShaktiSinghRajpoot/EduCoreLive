-- ============================================================================
-- When was this staff member deactivated?
--
-- WHY. The Inactive Staff list showed who was deactivated but not WHEN, so the
-- office had no way to tell a person who left last week from one who left two
-- years ago. core.staff only had updated_at, which moves on ANY edit (a phone
-- number change after the fact would overwrite it), so it cannot answer this.
--
-- status_changed_at is written only by the DEACTIVATE and REACTIVATE branches of
-- core.sp_staff_manage, so it always means "when the active/inactive state last
-- flipped" — nothing else touches it.
--
-- DELIBERATELY NULL FOR EXISTING ROWS. Rows deactivated before this column
-- existed have no honest value to fill in: updated_at is a guess, and a guess
-- printed as a date is worse than a blank. The UI shows a dash for those. Every
-- deactivation from now on records the real timestamp.
--
-- Target DB: PostgreSQL. Safe to re-run. Additive only — no signature changes,
-- so a build that knows nothing about the column keeps working.
-- ============================================================================

ALTER TABLE core.staff
    ADD COLUMN IF NOT EXISTS status_changed_at timestamptz;

-- Re-run afterwards so the write and the read both know about it:
--     sp_staff_manage.sql   (DEACTIVATE + REACTIVATE set it)
--     staff_list.sql        (returns it for the Inactive page)
