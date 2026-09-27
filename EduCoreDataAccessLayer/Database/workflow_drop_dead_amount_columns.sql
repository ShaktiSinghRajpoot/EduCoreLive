-- ============================================================================
-- Drop the two fee amounts that nothing has written since the amounts moved to
-- Fee Heads.
--
-- core.school_admission_workflow_settings still carries registration_fee_amount
-- and security_fee_amount. workflow_remove_fee_amounts.sql took them out of the
-- procedure, so since then they have held whatever they held on that day --
-- 0.00 everywhere -- while the real amounts live as Fee Heads with a Registration
-- or Admission collection point.
--
-- A column nothing maintains is worse than no column: it reads like an answer.
-- The next report to join on registration_fee_amount would quietly bill zero,
-- and nothing about the schema would warn whoever wrote it. charge_fees_from was
-- dropped from this same table for the same reason when it moved to the academic
-- year (fee_charge_from_per_year.sql); these two are the leftovers.
--
-- Safe to re-run.
-- ============================================================================

-- Refuse rather than destroy, if a value ever appeared: the whole premise is
-- that these are dead, and a non-zero one means something started writing them
-- again and this migration is out of date.
DO $guard$
DECLARE
    v_rows integer;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'core'
                  AND table_name   = 'school_admission_workflow_settings'
                  AND column_name  = 'registration_fee_amount') THEN

        EXECUTE $q$
            SELECT count(*) FROM core.school_admission_workflow_settings
             WHERE COALESCE(registration_fee_amount, 0) <> 0
                OR COALESCE(security_fee_amount, 0) <> 0
        $q$ INTO v_rows;

        IF v_rows > 0 THEN
            RAISE EXCEPTION
                'Not dropping: % school(s) have a non-zero registration_fee_amount or security_fee_amount. Something is writing these again — check before removing them.',
                v_rows;
        END IF;
    END IF;
END
$guard$;

ALTER TABLE core.school_admission_workflow_settings
    DROP COLUMN IF EXISTS registration_fee_amount,
    DROP COLUMN IF EXISTS security_fee_amount;
