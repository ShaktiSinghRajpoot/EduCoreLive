-- ============================================================================
-- Fee Head — cascade delete
--
-- Deleting a fee head must remove it from EVERYWHERE it is used, not just hide
-- the head. This proc force-removes the head and everything tied to it:
--   • core.school_fee_structure_details   — drop the head from every class structure
--   • core.school_fee_structures           — recompute each affected class's rollups
--   • core.student_fee_plan                — drop the head from every student's plan
--   • core.student_ledger                  — drop ALL the head's dues (paid + unpaid)
--   • core.school_fee_heads                — soft-delete the head itself
--
-- Receipts (core.fee_payments + core.fee_payment_details) are LEFT INTACT — they
-- store their own snapshot of the head name/amount and remain printable from
-- payment history. Only the live ledger/config is purged.
--
-- The ledger has no fee_head_id, so its rows are matched by fee_head_name (which
-- is unique per school). Rollups mirror the Fee Structure screen's formula:
--   annual = one_time + monthly*12 + quarterly*4 + half_yearly*2 + yearly
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_fee_head_delete_cascade(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_fee_head_id    integer,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name        varchar(80);
    v_structs     integer[];
    v_struct_rows integer := 0;
    v_plan_rows   integer := 0;
    v_ledger_rows integer := 0;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_fee_head_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid request.';
    END IF;

    SELECT fee_head_name INTO v_name
    FROM core.school_fee_heads
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id
      AND COALESCE(is_deleted, FALSE) = FALSE;

    IF v_name IS NULL THEN
        OPEN p_result FOR SELECT FALSE AS success, 'Fee head not found.' AS message;
        RETURN;
    END IF;

    -- Which class structures reference this head (need the ids before deleting).
    SELECT array_agg(DISTINCT fee_structure_id) INTO v_structs
    FROM core.school_fee_structure_details
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

    -- 1. Remove the head from every class fee structure.
    DELETE FROM core.school_fee_structure_details
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id;
    GET DIAGNOSTICS v_struct_rows = ROW_COUNT;

    -- 2. Recompute rollups for the affected structures from what remains.
    IF v_structs IS NOT NULL THEN
        UPDATE core.school_fee_structures fs
        SET one_time_total = COALESCE(t.one_time, 0),
            monthly_total  = COALESCE(t.monthly, 0),
            yearly_total   = COALESCE(t.yearly, 0),
            annual_total   = COALESCE(t.annual, 0),
            updated_by     = p_action_user_id,
            updated_at     = NOW()
        FROM (
            SELECT d.fee_structure_id,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'one time')    AS one_time,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'monthly')     AS monthly,
                   SUM(d.amount) FILTER (WHERE lower(d.frequency) NOT IN ('one time','monthly','quarterly','half yearly')) AS yearly,
                   ( COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'one time'), 0)
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'monthly'), 0) * 12
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'quarterly'), 0) * 4
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) = 'half yearly'), 0) * 2
                   + COALESCE(SUM(d.amount) FILTER (WHERE lower(d.frequency) NOT IN ('one time','monthly','quarterly','half yearly')), 0)
                   ) AS annual
            FROM core.school_fee_structure_details d
            WHERE d.fee_structure_id = ANY(v_structs)
            GROUP BY d.fee_structure_id
        ) t
        WHERE fs.fee_structure_id = t.fee_structure_id;

        -- Structures left with no details at all → zero the totals.
        UPDATE core.school_fee_structures fs
        SET one_time_total = 0, monthly_total = 0, yearly_total = 0, annual_total = 0,
            updated_by = p_action_user_id, updated_at = NOW()
        WHERE fs.fee_structure_id = ANY(v_structs)
          AND NOT EXISTS (
              SELECT 1 FROM core.school_fee_structure_details d
              WHERE d.fee_structure_id = fs.fee_structure_id);
    END IF;

    -- 3. Remove the head from every student's frozen plan.
    DELETE FROM core.student_fee_plan
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND (fee_head_id = p_fee_head_id OR fee_head_name = v_name);
    GET DIAGNOSTICS v_plan_rows = ROW_COUNT;

    -- 4. Remove ALL the head's dues from the ledger (paid + unpaid). Receipts are
    --    independent snapshots and are not touched.
    DELETE FROM core.student_ledger
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND fee_head_name = v_name;
    GET DIAGNOSTICS v_ledger_rows = ROW_COUNT;

    -- 5. Soft-delete the head itself.
    UPDATE core.school_fee_heads
    SET is_deleted = TRUE, is_active = FALSE, updated_by = p_action_user_id, updated_at = NOW()
    WHERE fee_head_id = p_fee_head_id AND tenant_id = p_tenant_id AND school_id = p_school_id;

    OPEN p_result FOR
    SELECT TRUE AS success,
           format('"%s" deleted — removed from %s structure row(s), %s plan row(s) and %s ledger due(s).',
                  v_name, v_struct_rows, v_plan_rows, v_ledger_rows) AS message,
           v_struct_rows AS structure_rows,
           v_plan_rows   AS plan_rows,
           v_ledger_rows AS ledger_rows;
END;
$procedure$;
