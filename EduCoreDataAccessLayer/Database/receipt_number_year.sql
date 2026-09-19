-- ============================================================================
-- Receipt numbers: derive the year properly instead of chopping the session name.
--
-- THE BUG. sp_fee_payment_collect built the receipt number as
--
--     v_year := left(COALESCE(NULLIF(trim(p_fin_year),''), to_char(v_date,'YYYY')), 4);
--     v_receipt := 'RCP-' || v_year || '-' || lpad(seq, 4, '0');
--
-- Taking the first four characters of the session NAME only works when the school
-- happens to name it "2026-2027". A school whose session is called "FY 26-27"
-- gets:
--
--     RCP-FY 2-0001
--
-- — a space in the middle of a receipt number handed to a parent, and a prefix
-- ("FY 2") that means nothing. It is also the key of core.receipt_counters, so
-- the numbering sequence hangs off a truncated label.
--
-- THE FIX. core.fn_receipt_year resolves the year the way a human would:
--
--   1. the session's own start_date year — the school told us when the year
--      begins, so use it;
--   2. failing that, the first four-digit run in the name ("FY 2026-27" -> 2026);
--   3. failing that, a two-digit run expanded to 20xx ("FY 26-27" -> 2026);
--   4. failing that, the payment date's year.
--
-- Existing receipts are NOT renumbered. A receipt number is printed, filed and
-- quoted by parents; rewriting old ones would break every reference to them.
-- Old and new simply coexist, which is normal for a numbering scheme that
-- changes mid-life.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE OR REPLACE FUNCTION core.fn_receipt_year(
    p_tenant_id integer,
    p_school_id integer,
    p_fin_year  text,
    p_date      date
) RETURNS text
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
    v_name  text := NULLIF(TRIM(COALESCE(p_fin_year, '')), '');
    v_start date;
    v_hit   text;
BEGIN
    IF v_name IS NULL THEN
        RETURN to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY');
    END IF;

    -- 1. The school already told us when this session starts.
    SELECT start_date INTO v_start
    FROM academic.academic_years
    WHERE tenant_id = p_tenant_id AND school_id = p_school_id
      AND academic_year_name = v_name
      AND COALESCE(is_deleted, FALSE) = FALSE
    LIMIT 1;

    IF v_start IS NOT NULL THEN
        RETURN to_char(v_start, 'YYYY');
    END IF;

    -- 2. A four-digit year anywhere in the name.
    v_hit := substring(v_name from '\d{4}');
    IF v_hit IS NOT NULL THEN
        RETURN v_hit;
    END IF;

    -- 3. A two-digit year: "FY 26-27" -> 2026. Assumes this century, which is
    --    the only reading that makes sense for a school session.
    v_hit := substring(v_name from '\d{2}');
    IF v_hit IS NOT NULL THEN
        RETURN '20' || v_hit;
    END IF;

    -- 4. Nothing usable in the name.
    RETURN to_char(COALESCE(p_date, CURRENT_DATE), 'YYYY');
END
$fn$;
