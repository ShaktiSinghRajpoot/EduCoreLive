-- ============================================================================
-- School settings rows must belong to a real (tenant, school) pair.
--
-- The profile, print-format and admission-workflow procs take tenant_id and
-- school_id as two separate values (both from login claims) and only checked
-- tenant > 1 and school > 0. A call with our tenant and ANOTHER tenant's school
-- wrote rows under a pair that does not exist in core.schools, and reported
-- success. Claims make that unlikely, but nothing in the database stopped it.
--
-- A composite foreign key on each settings table closes it for every writer at
-- once, without redefining five procs. school_purge.sql already deletes these
-- child rows before the school, so purge keeps working.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

-- school_id alone is the primary key, so this pair is unique already; the
-- constraint just lets the foreign keys below point at it.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'core.schools'::regclass AND conname = 'uq_schools_tenant_school') THEN
        ALTER TABLE core.schools ADD CONSTRAINT uq_schools_tenant_school UNIQUE (tenant_id, school_id);
    END IF;
END $$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['school_profiles', 'school_addresses', 'school_contacts',
                             'school_settings', 'school_admission_workflow_settings']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conrelid = ('core.' || t)::regclass AND conname = 'fk_' || t || '_school') THEN
            EXECUTE format(
                'ALTER TABLE core.%I ADD CONSTRAINT %I FOREIGN KEY (tenant_id, school_id) '
                'REFERENCES core.schools (tenant_id, school_id)',
                t, 'fk_' || t || '_school');
        END IF;
    END LOOP;
END $$;
