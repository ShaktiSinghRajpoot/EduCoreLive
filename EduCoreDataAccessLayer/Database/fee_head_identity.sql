-- ============================================================================
-- Fee Head: the name is the identity, so protect it.
--
-- core.student_ledger carries fee_head_name and NO fee_head_id (see
-- fee_head_cascade_delete.sql, which matches on the name for exactly that
-- reason). The name is therefore the join key for every due, every receipt line
-- and every report -- the same shape that class_name has, and the same three
-- problems:
--
--   1. Uniqueness was case-sensitive, so "Tuition Fee" and "tuition fee" were
--      two heads writing two sets of ledger rows that read identically on
--      screen and never added up together in a report.
--   2. Renaming a head left every row already written under the old name
--      behind, splitting one fee into two everywhere.
--   3. Deleting a head purged its dues INCLUDING the paid ones, leaving
--      receipts pointing at dues that no longer exist.
--
-- Safe to re-run. Step 1 refuses to create the index if case-duplicates exist
-- and names them, rather than failing halfway.
-- ============================================================================

-- ── 1. Uniqueness becomes case-insensitive ─────────────────────────────────
DO $ix$
DECLARE
    v_dups text;
BEGIN
    SELECT string_agg(format('%s (tenant %s, school %s, %s copies)',
                             lower(fee_head_name), tenant_id, school_id, n), '; ')
      INTO v_dups
    FROM (
        SELECT tenant_id, school_id, lower(fee_head_name) AS fee_head_name, count(*) AS n
          FROM core.school_fee_heads
         WHERE COALESCE(is_deleted, FALSE) = FALSE
         GROUP BY 1, 2, 3
        HAVING count(*) > 1) d;

    IF v_dups IS NOT NULL THEN
        -- Merging them is not a blind UPDATE: each one may already own ledger
        -- rows, so a human has to decide which name survives.
        RAISE WARNING 'Index NOT created, these names differ only by case: %', v_dups;
    ELSE
        DROP INDEX IF EXISTS core.uq_school_fee_heads_name;
        CREATE UNIQUE INDEX IF NOT EXISTS uq_school_fee_heads_name
            ON core.school_fee_heads (tenant_id, school_id, lower(fee_head_name))
            WHERE COALESCE(is_deleted, FALSE) = FALSE;
    END IF;
END
$ix$;


-- ── 2. Save: a rename carries the name with it ─────────────────────────────
-- p_display_order is gone, which is a new signature, so the old overload has to
-- go or calls fail with "procedure is not unique".
DROP PROCEDURE IF EXISTS core.sp_school_admin_fee_head_manage(
    character varying, integer, integer, integer, integer, character varying,
    character varying, numeric, character varying, character varying,
    character varying, boolean, integer, refcursor);

CREATE OR REPLACE PROCEDURE core.sp_school_admin_fee_head_manage(
    IN    p_operation        character varying,
    IN    p_tenant_id        integer,
    IN    p_school_id        integer,
    IN    p_action_user_id   integer,
    IN    p_fee_head_id      integer   DEFAULT 0,
    IN    p_fee_head_name    character varying DEFAULT NULL::character varying,
    IN    p_frequency        character varying DEFAULT NULL::character varying,
    IN    p_default_amount   numeric   DEFAULT 0,
    IN    p_fee_type         character varying DEFAULT NULL::character varying,
    IN    p_fee_group        character varying DEFAULT 'Academic'::character varying,
    IN    p_collection_point character varying DEFAULT 'Recurring'::character varying,
    IN    p_is_refundable    boolean   DEFAULT false,
    INOUT p_result           refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_name      varchar(80);
    v_old_name  varchar(80);
    v_moved     integer := 0;
    v_n         integer;
    v_active    boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetFeeHead' THEN

        -- Inactive heads are returned too: this is the master list, and callers
        -- that must not charge an inactive head filter on is_active themselves
        -- (the fee-structure picker, the admission fee list). Dropping them here
        -- would break the by-id enrichment that gives a saved structure row its
        -- collection point.
        OPEN p_result FOR
        SELECT
            fee_head_id, tenant_id, school_id, fee_head_name, frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type, fee_group,
            COALESCE(collection_point, 'Recurring') AS collection_point,
            COALESCE(is_refundable, FALSE) AS is_refundable,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        ORDER BY fee_head_name;

    ELSIF p_operation = 'GetFeeHeadById' THEN

        OPEN p_result FOR
        SELECT
            fee_head_id, tenant_id, school_id, fee_head_name, frequency,
            COALESCE(default_amount, 0) AS default_amount,
            fee_type, fee_group,
            COALESCE(collection_point, 'Recurring') AS collection_point,
            COALESCE(is_refundable, FALSE) AS is_refundable,
            COALESCE(is_active, TRUE) AS is_active
        FROM core.school_fee_heads
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE;

    ELSIF p_operation = 'SaveFeeHead' THEN

        v_name := trim(COALESCE(p_fee_head_name, ''));
        IF v_name = '' THEN
            RAISE EXCEPTION 'Fee head name is required.';
        END IF;

        -- The name is the join key, so a negative amount or an unknown cycle
        -- would be written straight into every student's ledger.
        IF COALESCE(p_default_amount, 0) < 0 THEN
            RAISE EXCEPTION 'Amount for "%" cannot be negative.', v_name;
        END IF;
        IF lower(trim(COALESCE(p_frequency, ''))) NOT IN
               ('one time', 'monthly', 'quarterly', 'half yearly', 'yearly') THEN
            RAISE EXCEPTION 'Unknown billing cycle "%" for "%".', p_frequency, v_name;
        END IF;
        IF COALESCE(p_collection_point, 'Recurring') NOT IN
               ('Registration', 'Admission', 'Recurring') THEN
            RAISE EXCEPTION 'Unknown collection point "%" for "%".', p_collection_point, v_name;
        END IF;

        -- Only on a RENAME. Saving a NEW head under an existing name stays an
        -- upsert on purpose (settings_tests C4): it revives a head someone had
        -- deleted instead of complaining about a row the user cannot see. What
        -- must never happen is renaming head A onto head B's name -- that used
        -- to reach the unique index and come back as a raw 500.
        IF COALESCE(p_fee_head_id, 0) > 0 AND EXISTS (
            SELECT 1 FROM core.school_fee_heads
             WHERE tenant_id = p_tenant_id AND school_id = p_school_id
               AND COALESCE(is_deleted, FALSE) = FALSE
               AND lower(fee_head_name) = lower(v_name)
               AND fee_head_id <> p_fee_head_id
        ) THEN
            RAISE EXCEPTION 'A fee head named "%" already exists.', v_name;
        END IF;

        IF COALESCE(p_fee_head_id, 0) > 0 THEN

            SELECT fee_head_name INTO v_old_name
            FROM core.school_fee_heads
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_id = p_fee_head_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            IF v_old_name IS NULL THEN
                OPEN p_result FOR SELECT FALSE AS success, 'Fee head not found.' AS message;
                RETURN;
            END IF;

            UPDATE core.school_fee_heads
            SET fee_head_name    = v_name,
                frequency        = p_frequency,
                default_amount   = COALESCE(p_default_amount, 0),
                fee_type         = p_fee_type,
                fee_group        = COALESCE(p_fee_group, 'Academic'),
                collection_point = COALESCE(p_collection_point, 'Recurring'),
                is_refundable    = COALESCE(p_is_refundable, FALSE),
                updated_by       = p_action_user_id,
                updated_at       = NOW()
            WHERE tenant_id = p_tenant_id AND school_id = p_school_id
              AND fee_head_id = p_fee_head_id
              AND COALESCE(is_deleted, FALSE) = FALSE;

            -- Carry the rename into everything already written under the old
            -- name. Without this a typo fix ("Tution" -> "Tuition") leaves the
            -- old rows behind and every report shows one fee as two. Only the
            -- label moves; no amount is touched.
            IF v_old_name IS DISTINCT FROM v_name THEN
                UPDATE core.student_ledger SET fee_head_name = v_name
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;

                UPDATE core.student_fee_plan SET fee_head_name = v_name
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;

                UPDATE core.school_fee_structure_details SET fee_head_name = v_name
                 WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                   AND fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;

                -- Receipt lines move too. A receipt is a snapshot of amounts,
                -- not of spelling, and leaving them behind is what splits a
                -- collection report down the middle.
                UPDATE core.fee_payment_details SET fee_head_name = v_name
                 WHERE fee_head_name = v_old_name;
                GET DIAGNOSTICS v_n = ROW_COUNT; v_moved := v_moved + v_n;
            END IF;

        ELSE
            INSERT INTO core.school_fee_heads
                (tenant_id, school_id, fee_head_name, frequency, default_amount,
                 fee_type, fee_group, collection_point, is_refundable,
                 is_active, is_deleted, created_by, created_at)
            VALUES
                (p_tenant_id, p_school_id, v_name, p_frequency, COALESCE(p_default_amount, 0),
                 p_fee_type, COALESCE(p_fee_group, 'Academic'),
                 COALESCE(p_collection_point, 'Recurring'), COALESCE(p_is_refundable, FALSE),
                 TRUE, FALSE, p_action_user_id, NOW())
            ON CONFLICT (tenant_id, school_id, lower(fee_head_name))
                WHERE COALESCE(is_deleted, FALSE) = FALSE
            DO UPDATE SET
                frequency        = EXCLUDED.frequency,
                default_amount   = EXCLUDED.default_amount,
                fee_type         = EXCLUDED.fee_type,
                fee_group        = EXCLUDED.fee_group,
                collection_point = EXCLUDED.collection_point,
                is_refundable    = EXCLUDED.is_refundable,
                is_active        = TRUE,
                is_deleted       = FALSE,
                updated_by       = p_action_user_id,
                updated_at       = NOW();
        END IF;

        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN v_moved > 0
                    THEN format('"%s" saved — renamed from "%s" on %s existing row(s).',
                                v_name, v_old_name, v_moved)
                    ELSE format('"%s" saved.', v_name)
               END AS message;

    ELSIF p_operation = 'ToggleFeeHeadStatus' THEN

        UPDATE core.school_fee_heads
        SET is_active  = NOT COALESCE(is_active, TRUE),
            updated_by = p_action_user_id,
            updated_at = NOW()
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND fee_head_id = p_fee_head_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        RETURNING fee_head_name, is_active INTO v_name, v_active;

        IF v_name IS NULL THEN
            OPEN p_result FOR SELECT FALSE AS success, 'Fee head not found.' AS message;
            RETURN;
        END IF;

        -- Say which way it went. "Status updated" told the user nothing, and
        -- this flag now actually stops the head being charged.
        OPEN p_result FOR
        SELECT TRUE AS success,
               CASE WHEN v_active
                    THEN format('"%s" is active again and will be charged on new admissions.', v_name)
                    ELSE format('"%s" is now inactive — it stays on past records but will not be charged again.', v_name)
               END AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;


-- ── 3. Delete: never purge a due that money has touched ────────────────────
-- The cascade itself is deliberate (see fee_head_cascade_delete.sql) -- a head
-- removed from the master must leave the structures and plans too. What it must
-- not do is delete a due that has been paid, waived or refunded: the receipt in
-- core.fee_payment_details survives and would point at nothing, so the money
-- collected can no longer be reconciled against what it was collected for.
-- Deactivating is the answer there, and the message says so.
CREATE OR REPLACE FUNCTION core.fn_fee_head_delete_guard(
    p_tenant_id integer, p_school_id integer, p_name varchar)
RETURNS integer
LANGUAGE sql STABLE AS $$
    SELECT COUNT(*)::integer
      FROM core.student_ledger
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND fee_head_name = p_name
       AND (COALESCE(amount_paid, 0) > 0
         OR COALESCE(concession, 0) > 0
         OR COALESCE(refund_amount, 0) > 0);
$$;

COMMENT ON FUNCTION core.fn_fee_head_delete_guard(integer, integer, varchar) IS
    'How many of this fee head''s dues have money against them. Non-zero means the head cannot be deleted, only deactivated.';


-- ── 4. display_order goes ──────────────────────────────────────────────────
-- Stored, passed through every layer, and never once set: 22 heads on Railway,
-- one distinct value, nothing non-zero, no input anywhere on the page. The only
-- ORDER BY on it therefore sorted by name in practice, which is what the
-- procedures now say out loud. Kept "in case", it is the same dead weight as
-- registration_fee_amount sitting at 0.00 long after the amounts moved.
ALTER TABLE core.school_fee_heads DROP COLUMN IF EXISTS display_order;
