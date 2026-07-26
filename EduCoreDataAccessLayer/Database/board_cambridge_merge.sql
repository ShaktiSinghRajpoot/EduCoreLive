-- ============================================================================
-- Merge the duplicate Cambridge boards.
--
-- config.boards carried two rows for the same board:
--     5  Cambridge          (CAMBRIDGE)
--    10  Cambridge (IGCSE)  (IGCSE)
--
-- These are not two boards. The board is Cambridge Assessment International
-- Education (CAIE); IGCSE is one QUALIFICATION LEVEL inside it (Cambridge Upper
-- Secondary), alongside Cambridge Primary, Lower Secondary and AS/A Level. A
-- school is affiliated to Cambridge and offers IGCSE — it is not "an IGCSE
-- board school". Two rows just split the same schools into two buckets and made
-- the board filter on the school list undercount.
--
-- KEEPING row 5 (lower id, and its CAMBRIDGE code is the honest name for the
-- board), RETIRING row 10, and renaming 5 to "Cambridge International (CAIE)"
-- so nobody reads the merge as "IGCSE support was removed".
--
-- SAFETY: verified before writing this — 0 schools referenced either row, there
-- are no FK constraints on config.boards, core.school_profiles.board_id is the
-- only column that references it, and core.students.prev_board is free text and
-- empty. The repoint below is therefore a no-op today; it is kept so this stays
-- correct if run against another environment where row 10 IS in use.
--
-- Soft delete, not DELETE: an is_deleted row keeps historical joins resolving
-- (every board join in the app filters is_deleted = FALSE, so it disappears from
-- dropdowns and filters immediately). Re-runnable.
-- ============================================================================

DO $merge$
DECLARE
    v_keep   integer;
    v_retire integer;
    v_moved  integer := 0;
BEGIN
    -- Resolve by code, not by id: ids differ between environments.
    SELECT board_id INTO v_keep
    FROM config.boards
    WHERE board_code = 'CAMBRIDGE' AND is_deleted = FALSE;

    SELECT board_id INTO v_retire
    FROM config.boards
    WHERE board_code = 'IGCSE' AND is_deleted = FALSE;

    IF v_keep IS NULL THEN
        RAISE NOTICE 'No active CAMBRIDGE board row — nothing to merge.';
        RETURN;
    END IF;

    IF v_retire IS NOT NULL THEN
        -- Move any school off the duplicate before retiring it.
        UPDATE core.school_profiles
        SET board_id   = v_keep,
            updated_at = NOW()
        WHERE board_id = v_retire;

        GET DIAGNOSTICS v_moved = ROW_COUNT;

        UPDATE config.boards
        SET is_deleted = TRUE,
            deleted_at = NOW(),
            deleted_by = 1
        WHERE board_id = v_retire;

        RAISE NOTICE 'Merged board % into % (% school(s) moved).', v_retire, v_keep, v_moved;
    ELSE
        RAISE NOTICE 'No active IGCSE row — already merged.';
    END IF;

    -- Canonical name. IGCSE is named explicitly so the dropdown still reads as
    -- the right choice for an IGCSE school.
    UPDATE config.boards
    SET name          = 'Cambridge International (CAIE / IGCSE)',
        display_order = 5
    WHERE board_id = v_keep
      AND name <> 'Cambridge International (CAIE / IGCSE)';
END
$merge$;

-- ── Close the display_order gap left by the retired row ────────────────────
-- Retiring IGCSE (order 6) left 1,2,3,4,5,7,8. Harmless for sorting, but a gap
-- invites someone to "fix" it by hand later and get it wrong.
--
-- Renumbers by CURRENT order, so it preserves the sequence rather than imposing
-- one, and is self-healing for any future gap — safe to re-run any time.
-- No tenant partition: config.boards is platform data with no tenant_id
-- (see platform_masters_drop_tenant.sql).
WITH ordered AS (
    SELECT board_id,
           ROW_NUMBER() OVER (ORDER BY display_order, name) AS rn
    FROM config.boards
    WHERE is_deleted = FALSE
)
UPDATE config.boards b
SET display_order = o.rn
FROM ordered o
WHERE b.board_id = o.board_id
  AND b.display_order <> o.rn;
