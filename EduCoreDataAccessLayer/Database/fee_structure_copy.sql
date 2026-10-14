-- ============================================================================
-- Copy the fee structure into a new session (School Setup › Fee Structure)
--
-- A new session starts with no fee structure, so promotion billed nobody until
-- every class was typed in again by hand. This copies each class's structure
-- from an earlier session, optionally raised by a percentage (rounded to whole
-- rupees). Classes that already have a structure in the target session are
-- left as they are, so it is safe to run twice.
--
-- The totals are worked out the same way SaveFeeStructure does it
-- (fee_structure_manage.sql): by each fee head's cycle.
--
--   core.sp_fee_structure_copy(tenant, school, user, from_year, to_year, increase_percent)
--   one row: copied (classes), skipped (already had one), message
--
-- Target DB: PostgreSQL (educore). Safe to re-run.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_fee_structure_copy(
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_from_year        varchar,
    IN    p_to_year          varchar,
    IN    p_increase_percent numeric DEFAULT 0,
    INOUT p_result           refcursor DEFAULT 'fee_copy_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    src        record;
    v_new_id   integer;
    v_factor   numeric := 1 + COALESCE(p_increase_percent, 0) / 100;
    v_copied   integer := 0;
    v_skipped  integer := 0;
    v_one      numeric; v_mon numeric; v_qtr numeric; v_half numeric; v_year numeric;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;
    IF COALESCE(trim(p_from_year), '') = '' OR COALESCE(trim(p_to_year), '') = '' THEN
        RAISE EXCEPTION 'Choose the session to copy from and the session to copy into.';
    END IF;
    IF p_from_year = p_to_year THEN
        RAISE EXCEPTION 'Choose two different sessions.';
    END IF;
    IF COALESCE(p_increase_percent, 0) < 0 OR COALESCE(p_increase_percent, 0) > 100 THEN
        RAISE EXCEPTION 'The increase must be between 0 and 100 percent.';
    END IF;

    FOR src IN
        SELECT s.fee_structure_id, s.class_name
          FROM core.school_fee_structures s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
           AND s.academic_year = p_from_year AND NOT COALESCE(s.is_deleted, FALSE)
         ORDER BY s.class_name
    LOOP
        -- a class already set up in the new session keeps its own structure
        IF EXISTS (SELECT 1 FROM core.school_fee_structures t
                    WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id
                      AND t.class_name = src.class_name AND t.academic_year = p_to_year
                      AND NOT COALESCE(t.is_deleted, FALSE)) THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        -- totals by the fee head's cycle, from the new (raised, whole-rupee) amounts
        SELECT COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'one time'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'monthly'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'quarterly'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle = 'half yearly'), 0),
               COALESCE(SUM(x.amount) FILTER (WHERE x.cycle NOT IN ('one time', 'monthly', 'quarterly', 'half yearly')), 0)
          INTO v_one, v_mon, v_qtr, v_half, v_year
          FROM (SELECT lower(trim(h.frequency)) AS cycle, ROUND(d.amount * v_factor) AS amount
                  FROM core.school_fee_structure_details d
                  JOIN core.school_fee_heads h ON h.fee_head_id = d.fee_head_id
                 WHERE d.fee_structure_id = src.fee_structure_id
                   AND NOT COALESCE(d.is_deleted, FALSE) AND COALESCE(d.is_selected, TRUE)
                   AND NOT COALESCE(h.is_deleted, FALSE)) x;

        -- a deleted row of the same class + session is reused (the key is unique)
        INSERT INTO core.school_fee_structures
            (tenant_id, school_id, class_name, academic_year,
             one_time_total, monthly_total, quarterly_total, half_yearly_total,
             yearly_total, annual_total, is_active, is_deleted, created_by, created_at)
        VALUES
            (p_tenant_id, p_school_id, src.class_name, p_to_year,
             v_one, v_mon, v_qtr, v_half, v_year,
             v_one + v_mon * 12 + v_qtr * 4 + v_half * 2 + v_year,
             TRUE, FALSE, p_action_user_id, now())
        ON CONFLICT (tenant_id, school_id, class_name, academic_year) DO UPDATE
           SET one_time_total = EXCLUDED.one_time_total, monthly_total = EXCLUDED.monthly_total,
               quarterly_total = EXCLUDED.quarterly_total, half_yearly_total = EXCLUDED.half_yearly_total,
               yearly_total = EXCLUDED.yearly_total, annual_total = EXCLUDED.annual_total,
               is_active = TRUE, is_deleted = FALSE, updated_by = p_action_user_id, updated_at = now()
        RETURNING fee_structure_id INTO v_new_id;

        -- clear what a deleted row may still hold, then copy the heads
        DELETE FROM core.school_fee_structure_details WHERE fee_structure_id = v_new_id;
        INSERT INTO core.school_fee_structure_details
            (tenant_id, school_id, fee_structure_id, fee_head_id, fee_head_name,
             frequency, amount, is_selected, is_deleted, created_by, created_at)
        SELECT p_tenant_id, p_school_id, v_new_id, d.fee_head_id, h.fee_head_name,
               h.frequency, ROUND(d.amount * v_factor), TRUE, FALSE, p_action_user_id, now()
          FROM core.school_fee_structure_details d
          JOIN core.school_fee_heads h ON h.fee_head_id = d.fee_head_id
         WHERE d.fee_structure_id = src.fee_structure_id
           AND NOT COALESCE(d.is_deleted, FALSE) AND COALESCE(d.is_selected, TRUE)
           AND NOT COALESCE(h.is_deleted, FALSE);

        v_copied := v_copied + 1;
    END LOOP;

    IF v_copied = 0 AND v_skipped = 0 THEN
        RAISE EXCEPTION 'Session % has no fee structure to copy.', p_from_year;
    END IF;

    OPEN p_result FOR
    SELECT v_copied AS copied, v_skipped AS skipped,
           v_copied || ' class(es) copied into ' || p_to_year
           || CASE WHEN COALESCE(p_increase_percent, 0) > 0 THEN ' with a ' || trim_scale(p_increase_percent) || '% increase' ELSE '' END
           || CASE WHEN v_skipped > 0 THEN '; ' || v_skipped || ' already had a structure and were left as they are' ELSE '' END
           || '.' AS message;
END;
$procedure$;
