-- ============================================================================
-- Repair schools whose address state contradicts their board's state.
--
-- A State Board is granted by one state's education department, so a UP Board
-- school cannot be located in Bihar. Nothing enforced that until now, so the
-- SuperAdmin wizard could save a mismatched pair — and did:
--
--   SCH14  Mathma Gandhi Inter Collage
--          board          : State Board (Uttar Pradesh)
--          address state  : Andhra Pradesh          <-- impossible
--          address district: Alluri Sitharama Raju  <-- an AP district
--          address city   : Kasia                   <-- actually a UP town
--
-- The city being a UP town is what settles it: the school is in UP and the
-- state/district were picked wrongly. Confirmed with the platform owner.
--
-- BOARD STATE IS THE SOURCE OF TRUTH here, so the address follows it:
--   * state       -> the board's state
--   * district    -> CLEARED when it belongs to a different state, because an
--                    AP district under a UP state is not a value anyone can use.
--                    The school re-picks it from the (now correct) cascade.
--   * city/pincode-> left alone; they were already right.
--
-- Going forward this cannot recur: sp_school_manage now REJECTS a mismatched
-- pair, and sp_school_admin_basic_profile_manage FORCES the state to the board's.
-- Re-runnable: only touches rows that are still mismatched.
-- ============================================================================

UPDATE core.school_addresses a
SET state       = bstate.name,
    state_id    = bstate.state_id,
    country_id  = COALESCE(a.country_id, bstate.country_id),
    -- Keep the district only if it actually belongs to the board's state.
    -- Scalar subqueries, not a join: Postgres will not let a FROM-list join
    -- condition reference the UPDATE target (a).
    district_id = CASE WHEN (SELECT d.state_id FROM config.districts d
                              WHERE d.district_id = a.district_id) = bstate.state_id
                       THEN a.district_id ELSE NULL END,
    district    = CASE WHEN (SELECT d.state_id FROM config.districts d
                              WHERE d.district_id = a.district_id) = bstate.state_id
                       THEN a.district ELSE NULL END,
    updated_at  = NOW()
FROM core.school_profiles sp
JOIN config.boards b       ON b.board_id  = sp.board_id AND b.requires_state = TRUE
JOIN config.states bstate  ON bstate.state_id = sp.board_state_id
WHERE sp.tenant_id = a.tenant_id
  AND sp.school_id = a.school_id
  AND sp.is_deleted = FALSE
  AND a.state_id IS DISTINCT FROM sp.board_state_id;

-- Anything still mismatched (should be none):
--   SELECT s.school_code, b.name, bs.name AS board_state, ast.name AS address_state
--   FROM core.schools s
--   JOIN core.school_profiles sp ON sp.school_id = s.school_id
--   JOIN config.boards b ON b.board_id = sp.board_id AND b.requires_state
--   LEFT JOIN config.states bs  ON bs.state_id  = sp.board_state_id
--   LEFT JOIN core.school_addresses a ON a.school_id = s.school_id AND a.is_primary
--   LEFT JOIN config.states ast ON ast.state_id = a.state_id
--   WHERE a.state_id IS DISTINCT FROM sp.board_state_id;
