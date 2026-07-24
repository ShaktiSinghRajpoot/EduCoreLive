-- ============================================================================
-- Fee-head name uniqueness should apply to ACTIVE heads only.
--
-- The old constraint UNIQUE (tenant_id, school_id, fee_head_name) counted
-- soft-deleted rows too, so:
--   * re-creating a head whose name was previously deleted, or
--   * an UPDATE that renamed a head onto a deleted name,
-- failed with "23505 duplicate key ... uq_school_fee_heads_name".
--
-- Replace it with a PARTIAL unique index that ignores soft-deleted rows, so a
-- deleted head's name is free to reuse. The fee-head save proc's ON CONFLICT is
-- updated to match this partial index (see fee_collection_point.sql).
--
-- Safe to re-run.
-- ============================================================================

ALTER TABLE core.school_fee_heads DROP CONSTRAINT IF EXISTS uq_school_fee_heads_name;
DROP INDEX  IF EXISTS core.uq_school_fee_heads_name;

CREATE UNIQUE INDEX IF NOT EXISTS uq_school_fee_heads_name
    ON core.school_fee_heads (tenant_id, school_id, fee_head_name)
    WHERE COALESCE(is_deleted, FALSE) = FALSE;
