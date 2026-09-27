-- ============================================================================
-- Retire fee structures that have no fee heads left.
--
-- A structure with zero details bills nothing, but the Fee Structure page listed
-- it like any other and the class read as configured. Seventeen of these were
-- sitting on the live database: every class from Class 2 to Class 12 including
-- all the stream classes, each with a header, zero details and a zero annual.
--
-- They were not half-finished saves -- there were no soft-deleted details either,
-- so nothing was ever removed from them in the ordinary way. They came from
-- fee_head_cascade_delete.sql, which HARD-deletes a head's structure rows and
-- then, for a structure left with nothing, zeroed the totals and left it alive.
-- Delete one fee head that every class shares and you get one of these per class.
--
-- That procedure now retires such a structure instead of zeroing it, so this
-- cleans up what it produced before the fix. Safe to re-run: it only touches
-- structures that have no live details at all.
-- ============================================================================

DO $retire$
DECLARE
    v_rows integer;
BEGIN
    UPDATE core.school_fee_structures fs
    SET one_time_total = 0, monthly_total = 0, quarterly_total = 0,
        half_yearly_total = 0, yearly_total = 0, annual_total = 0,
        is_deleted = TRUE, is_active = FALSE,
        updated_at = NOW()
    WHERE COALESCE(fs.is_deleted, FALSE) = FALSE
      AND NOT EXISTS (
          SELECT 1 FROM core.school_fee_structure_details d
           WHERE d.fee_structure_id = fs.fee_structure_id
             AND COALESCE(d.is_deleted, FALSE) = FALSE);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'Retired % empty fee structure(s). Those classes now read as not set up, which is what they are.', v_rows;
END
$retire$;
