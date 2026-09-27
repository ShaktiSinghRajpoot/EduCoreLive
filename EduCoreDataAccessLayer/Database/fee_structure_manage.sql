-- ============================================================================
-- Fee Structure — per class, per session: which fee heads apply and at what
-- amount.
--
-- This procedure had NO source in EduCoreDataAccessLayer/Database. It existed
-- only in the live databases and in database/backup_pre_cleanup/, so rebuilding
-- from the scripts produced a database without it. This file is now its home.
--
-- Two things are fixed here, and both come from the same place: saving a
-- structure used to be a header call followed by one call per fee head, each in
-- its own transaction (PgExec wraps every call).
--
--   * The header save soft-deletes the existing details before the new ones are
--     written. Anything going wrong between the two left a structure with a
--     header and NO details -- a class the page lists as configured that would
--     bill nothing. Two such rows exist locally (fee_structure_id 64 and 65).
--   * The C# loop skipped the details on an unexpected header result and still
--     reported success, so nobody saw it happen.
--
-- The details now arrive with the header as JSONB and the whole save is one
-- call, so it either happens or it does not. It also collapses 1 + N round
-- trips per class into one.
--
-- Quarterly and Half Yearly get their own totals. They were folded into
-- annual_total and nowhere else, so a school billing quarterly saw "Monthly 0"
-- beside a large annual figure with nothing to explain it. The rollup formula
-- matches fee_head_cascade_delete.sql, which recomputes these same columns:
--     annual = one_time + monthly*12 + quarterly*4 + half_yearly*2 + yearly
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

-- ── 1. The two missing rollup columns ──────────────────────────────────────
ALTER TABLE core.school_fee_structures
    ADD COLUMN IF NOT EXISTS quarterly_total   numeric(12,2) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS half_yearly_total numeric(12,2) NOT NULL DEFAULT 0;

-- ── 2. The procedure ───────────────────────────────────────────────────────
-- The save takes JSONB now and the per-head parameters are gone, which is a new
-- signature, so the old overload has to go or calls fail as ambiguous.
DROP PROCEDURE IF EXISTS core.sp_school_admin_fee_structure_manage(
    character varying, integer, integer, integer, integer, character varying,
    character varying, integer, character varying, character varying, numeric,
    numeric, numeric, numeric, numeric, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_fee_structure_manage(
    IN    p_operation       character varying,
    IN    p_tenant_id       integer,
    IN    p_school_id       integer,
    IN    p_action_user_id  integer,
    IN    p_fee_structure_id integer DEFAULT 0,
    IN    p_class_name      character varying DEFAULT NULL::character varying,
    IN    p_academic_year   character varying DEFAULT NULL::character varying,
    IN    p_details         jsonb   DEFAULT NULL::jsonb,
    INOUT p_result          refcursor DEFAULT 'result_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_fee_structure_id INTEGER;
    v_one_time    numeric := 0;
    v_monthly     numeric := 0;
    v_quarterly   numeric := 0;
    v_half_yearly numeric := 0;
    v_yearly      numeric := 0;
    v_annual      numeric := 0;
    v_count       INTEGER := 0;
BEGIN

    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetFeeStructure' THEN

        OPEN p_result FOR
        SELECT
            fs.fee_structure_id,
            fs.tenant_id,
            fs.school_id,
            fs.class_name,
            fs.academic_year,
            COALESCE(fs.one_time_total, 0)    AS one_time_total,
            COALESCE(fs.monthly_total, 0)     AS monthly_total,
            COALESCE(fs.quarterly_total, 0)   AS quarterly_total,
            COALESCE(fs.half_yearly_total, 0) AS half_yearly_total,
            COALESCE(fs.yearly_total, 0)      AS yearly_total,
            COALESCE(fs.annual_total, 0)      AS annual_total,
            COALESCE(fs.is_active, TRUE)      AS is_active,
            COALESCE(string_agg(fsd.fee_head_name, ', ' ORDER BY fsd.fee_head_name), '') AS fee_head_names,
            -- The page needs to tell "no heads" apart from "heads worth nothing";
            -- a structure with zero heads bills nothing and should say so.
            COUNT(fsd.fee_structure_detail_id)::int AS head_count,
            fs.created_by,
            fs.updated_by,
            COALESCE(fs.updated_at, fs.created_at) AS updated_at
        FROM core.school_fee_structures fs
        LEFT JOIN core.school_fee_structure_details fsd
            ON fsd.fee_structure_id = fs.fee_structure_id
           AND fsd.tenant_id = p_tenant_id
           AND fsd.school_id = p_school_id
           AND COALESCE(fsd.is_deleted, FALSE) = FALSE
           AND COALESCE(fsd.is_selected, TRUE) = TRUE
        WHERE fs.tenant_id = p_tenant_id
          AND fs.school_id = p_school_id
          AND COALESCE(fs.is_deleted, FALSE) = FALSE
        GROUP BY
            fs.fee_structure_id, fs.tenant_id, fs.school_id, fs.class_name,
            fs.academic_year, fs.one_time_total, fs.monthly_total,
            fs.quarterly_total, fs.half_yearly_total, fs.yearly_total,
            fs.annual_total, fs.is_active, fs.created_by, fs.updated_by,
            fs.created_at, fs.updated_at
        ORDER BY fs.academic_year DESC, fs.class_name;

    ELSIF p_operation = 'GetFeeStructureDetails' THEN

        OPEN p_result FOR
        SELECT
            fsd.fee_structure_detail_id,
            fsd.tenant_id,
            fsd.school_id,
            fsd.fee_structure_id,
            fsd.fee_head_id,
            fsd.fee_head_name,
            fsd.frequency,
            COALESCE(fsd.amount, 0)          AS amount,
            COALESCE(fsd.is_selected, TRUE)  AS is_selected
        FROM core.school_fee_structure_details fsd
        INNER JOIN core.school_fee_structures fs
            ON fs.fee_structure_id = fsd.fee_structure_id
           AND fs.tenant_id = p_tenant_id
           AND fs.school_id = p_school_id
           AND COALESCE(fs.is_deleted, FALSE) = FALSE
        WHERE fsd.tenant_id = p_tenant_id
          AND fsd.school_id = p_school_id
          AND fs.class_name = p_class_name
          AND fs.academic_year = p_academic_year
          AND COALESCE(fsd.is_deleted, FALSE) = FALSE
        ORDER BY fsd.frequency, fsd.fee_head_name;

    ELSIF p_operation = 'SaveFeeStructure' THEN

        -- One class, its whole structure, one transaction. p_details is
        -- [{feeHeadId, feeHeadName, frequency, amount}, ...].
        IF p_details IS NULL OR jsonb_array_length(p_details) = 0 THEN
            RAISE EXCEPTION 'No fee heads were sent for %.', p_class_name;
        END IF;

        -- Rollups are computed HERE, from the rows actually being written, so the
        -- stored totals cannot drift from the stored details.
        SELECT
            COALESCE(SUM(amount) FILTER (WHERE cycle = 'one time'),    0),
            COALESCE(SUM(amount) FILTER (WHERE cycle = 'monthly'),     0),
            COALESCE(SUM(amount) FILTER (WHERE cycle = 'quarterly'),   0),
            COALESCE(SUM(amount) FILTER (WHERE cycle = 'half yearly'), 0),
            COALESCE(SUM(amount) FILTER (WHERE cycle NOT IN
                        ('one time','monthly','quarterly','half yearly')), 0),
            COUNT(*)
          INTO v_one_time, v_monthly, v_quarterly, v_half_yearly, v_yearly, v_count
        FROM (
            SELECT lower(trim(COALESCE(d->>'frequency', 'Yearly'))) AS cycle,
                   COALESCE((d->>'amount')::numeric, 0)             AS amount
            FROM jsonb_array_elements(p_details) AS d
        ) t;

        v_annual := v_one_time + (v_monthly * 12) + (v_quarterly * 4)
                  + (v_half_yearly * 2) + v_yearly;

        INSERT INTO core.school_fee_structures
            (tenant_id, school_id, class_name, academic_year,
             one_time_total, monthly_total, quarterly_total, half_yearly_total,
             yearly_total, annual_total, is_active, is_deleted, created_by, created_at)
        VALUES
            (p_tenant_id, p_school_id, p_class_name, p_academic_year,
             v_one_time, v_monthly, v_quarterly, v_half_yearly,
             v_yearly, v_annual, TRUE, FALSE, p_action_user_id, NOW())
        ON CONFLICT (tenant_id, school_id, class_name, academic_year)
        DO UPDATE SET
            one_time_total    = EXCLUDED.one_time_total,
            monthly_total     = EXCLUDED.monthly_total,
            quarterly_total   = EXCLUDED.quarterly_total,
            half_yearly_total = EXCLUDED.half_yearly_total,
            yearly_total      = EXCLUDED.yearly_total,
            annual_total      = EXCLUDED.annual_total,
            is_active  = TRUE,
            is_deleted = FALSE,
            updated_by = p_action_user_id,
            updated_at = NOW()
        RETURNING fee_structure_id INTO v_fee_structure_id;

        -- Replace-all: the old rows go and the new ones land in the same
        -- transaction, so the window that produced header-without-details is gone.
        UPDATE core.school_fee_structure_details
        SET is_deleted = TRUE, is_selected = FALSE,
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_structure_id = v_fee_structure_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        -- uq_school_fee_structure_details_head covers soft-deleted rows too, so a
        -- head that was just marked deleted above still owns its key. Upsert onto
        -- it -- which is what the old per-head call did -- and the row comes back
        -- to life with the new amount instead of colliding.
        INSERT INTO core.school_fee_structure_details
            (tenant_id, school_id, fee_structure_id, fee_head_id, fee_head_name,
             frequency, amount, is_selected, is_deleted, created_by, created_at)
        SELECT
            p_tenant_id, p_school_id, v_fee_structure_id,
            NULLIF(COALESCE((d->>'feeHeadId')::int, 0), 0),
            COALESCE(d->>'feeHeadName', 'Fee'),
            COALESCE(d->>'frequency', 'Yearly'),
            COALESCE((d->>'amount')::numeric, 0),
            TRUE, FALSE, p_action_user_id, NOW()
        FROM jsonb_array_elements(p_details) AS d
        ON CONFLICT (tenant_id, school_id, fee_structure_id, fee_head_id)
        DO UPDATE SET
            fee_head_name = EXCLUDED.fee_head_name,
            frequency     = EXCLUDED.frequency,
            amount        = EXCLUDED.amount,
            is_selected   = TRUE,
            is_deleted    = FALSE,
            updated_by    = p_action_user_id,
            updated_at    = NOW();

        OPEN p_result FOR
        SELECT TRUE AS success,
               format('%s: %s fee head(s), %s a year.',
                      p_class_name, v_count, to_char(v_annual, 'FM999,999,990')) AS message,
               v_fee_structure_id AS fee_structure_id;

    ELSIF p_operation = 'DeleteFeeStructure' THEN

        UPDATE core.school_fee_structures
        SET is_deleted = TRUE, is_active = FALSE,
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_structure_id = p_fee_structure_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        IF NOT FOUND THEN
            OPEN p_result FOR SELECT FALSE AS success, 'Fee structure not found.' AS message;
            RETURN;
        END IF;

        UPDATE core.school_fee_structure_details
        SET is_deleted = TRUE, is_selected = FALSE,
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_structure_id = p_fee_structure_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

        OPEN p_result FOR SELECT TRUE AS success, 'Fee structure deleted.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;

END;
$procedure$;


-- ── 3. Backfill the two new totals on structures saved before this ─────────
UPDATE core.school_fee_structures fs
SET quarterly_total   = t.quarterly,
    half_yearly_total = t.half_yearly
FROM (
    SELECT d.fee_structure_id,
           COALESCE(SUM(d.amount) FILTER (WHERE lower(trim(d.frequency)) = 'quarterly'), 0)   AS quarterly,
           COALESCE(SUM(d.amount) FILTER (WHERE lower(trim(d.frequency)) = 'half yearly'), 0) AS half_yearly
    FROM core.school_fee_structure_details d
    WHERE COALESCE(d.is_deleted, FALSE) = FALSE
    GROUP BY d.fee_structure_id
) t
WHERE t.fee_structure_id = fs.fee_structure_id
  AND (fs.quarterly_total <> t.quarterly OR fs.half_yearly_total <> t.half_yearly);
