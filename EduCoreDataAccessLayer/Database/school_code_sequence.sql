-- ============================================================================
-- SCHOOL CODE — a real running sequence: SCH1, SCH2, SCH3, ...
--
-- HISTORY of this column:
--   1. 'SCH' || YYYYMMDDHH24MISS  — only unique to the second, so two schools
--      created in the same second on one tenant collided on
--      uq_school_code (tenant_id, school_code) and the second save died with a
--      raw constraint error.
--   2. 'SCH' || LPAD(school_id,5) — collision-proof, but school_id has GAPS
--      (an identity column still advances on a rolled-back insert), so the
--      codes jumped: SCH00019, SCH00024, ...
--   3. THIS — a counter row, incremented inside the caller's transaction.
--
-- WHY A COUNTER TABLE AND NOT A SEQUENCE:
--   nextval() does NOT roll back. A failed school save would burn a number and
--   leave a hole, which is the exact thing we're fixing. An UPDATE ... RETURNING
--   on a counter row DOES roll back with the transaction, so the numbering stays
--   gap-free. It also takes a row lock, so concurrent inserts serialise instead
--   of racing to the same number.
--   This is the pattern the codebase already uses for receipt / admission /
--   registration / TC numbers (core.*_counters).
--
-- Codes are GLOBAL, not per tenant: a super admin works across tenants, and one
-- "SCH7" that means exactly one school is far easier to support than a SCH7 in
-- every tenant.
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.school_code_counters (
    counter_key varchar(20) NOT NULL DEFAULT 'GLOBAL',
    last_seq    integer      NOT NULL DEFAULT 0,
    updated_at  timestamp    NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_school_code_counters PRIMARY KEY (counter_key)
);

INSERT INTO core.school_code_counters (counter_key, last_seq)
VALUES ('GLOBAL', 0)
ON CONFLICT (counter_key) DO NOTHING;

-- ── Renumber the schools that already exist ────────────────────────────────
-- Safe: school_code is display-only. Checked every proc first — it appears in
-- sp_school_list / sp_school_admin_basic_profile_manage as a
-- SELECTed column, an ILIKE search target and a sort key, never as a lookup key,
-- and no C# generates or matches on it.
--
-- Numbered by school_id, i.e. creation order, so the oldest school is SCH1.
DO $renumber$
DECLARE
    v_max integer;
BEGIN
    -- Two passes: park everything on a temporary code first, otherwise assigning
    -- SCH1..SCHn row by row can collide with a code another row still holds.
    UPDATE core.schools
    SET school_code = 'TMP#' || school_id
    WHERE school_code IS NULL OR school_code !~ '^SCH[0-9]+$'
       OR school_code IN (SELECT 'SCH' || rn FROM (
              SELECT ROW_NUMBER() OVER (ORDER BY school_id) AS rn FROM core.schools
          ) x);

    WITH ordered AS (
        SELECT school_id, ROW_NUMBER() OVER (ORDER BY school_id) AS rn
        FROM core.schools
    )
    UPDATE core.schools s
    SET school_code = 'SCH' || o.rn
    FROM ordered o
    WHERE s.school_id = o.school_id;

    SELECT COUNT(*) INTO v_max FROM core.schools;

    -- Next school continues from here.
    UPDATE core.school_code_counters
    SET last_seq = v_max, updated_at = NOW()
    WHERE counter_key = 'GLOBAL';

    RAISE NOTICE 'Renumbered % school(s); next code will be SCH%.', v_max, v_max + 1;
END
$renumber$;
