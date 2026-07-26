-- ============================================================================
-- STATE TEXT -> config.states, and the school-address cleanup that needed it.
--
-- geo_master.sql backfilled core.school_addresses.state_id by matching the free
-- text exactly against config.states.name. That left 5 rows unresolved, because
-- people don't type the official name:
--     UP · Jammu & Kashmir · Haryanafff · TEST
--
-- Rather than hand-patch those 5, this adds a REUSABLE resolver. Student, staff,
-- enquiry and transport addresses all still capture state as free text, so the
-- same problem is waiting in each of them — and any import/migration will hit it
-- too.
--
-- RESOLUTION ORDER (first hit wins):
--   1. exact name        "uttar pradesh"
--   2. ISO subdivision code   "UP", "MH", "TN"  (already on config.states)
--   3. alias table       old names, misspellings, "J&K", "NCR", "Orissa"
-- Everything is compared normalised: trimmed, lower-cased, '&' -> 'and',
-- punctuation stripped, runs of whitespace collapsed.
-- Re-runnable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.state_aliases (
    alias      varchar(100) NOT NULL,
    state_id   integer      NOT NULL REFERENCES config.states(state_id),
    CONSTRAINT pk_state_aliases PRIMARY KEY (alias)
);

COMMENT ON TABLE config.state_aliases IS
    'Old names, abbreviations and common misspellings that map onto config.states. Add a row instead of patching data by hand. Aliases are stored already-normalised (lower case, "and" not "&", no punctuation).';

-- Normalise once, in one place, so the resolver and the seed agree.
CREATE OR REPLACE FUNCTION config.fn_norm_state(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
        regexp_replace(
            regexp_replace(
                regexp_replace(lower(trim(COALESCE(p_text, ''))), '&', 'and', 'g'),
                '[^a-z0-9 ]', '', 'g'),
            '\s+', ' ', 'g'),
        '');
$$;

-- ── Aliases the code/name match cannot catch ───────────────────────────────
-- (2-letter codes like UP/MH/TN are NOT listed: config.states.state_code already
--  carries them and the resolver checks that directly.)
INSERT INTO config.state_aliases (alias, state_id)
SELECT config.fn_norm_state(a.alias), s.state_id
FROM (VALUES
    ('Orissa',                  'OR'),   -- renamed 2011
    ('Uttaranchal',             'UT'),   -- renamed 2007
    ('UK',                      'UT'),   -- common, and NOT the ISO code (that's UT)
    ('Pondicherry',             'PY'),   -- renamed 2006
    ('Pondy',                   'PY'),
    ('Chattisgarh',             'CT'),   -- frequent misspelling
    ('Chhatisgarh',             'CT'),
    ('Tamilnadu',               'TN'),
    ('Tamil Nadu State',        'TN'),
    ('Andhra',                  'AP'),
    ('J and K',                 'JK'),
    -- 'J&K' normalises to 'jandk' (no spaces, because '&'->'and' then punctuation
    -- is stripped), so it needs its own row — 'J and K' above does NOT cover it.
    ('J&K',                     'JK'),
    ('JandK',                   'JK'),
    ('Jammu Kashmir',           'JK'),
    ('NCR',                     'DL'),
    ('New Delhi',               'DL'),
    ('Delhi NCR',               'DL'),
    ('National Capital Territory of Delhi', 'DL'),
    ('Bombay',                  'MH'),
    ('Banaras',                 'UP'),
    ('Dadra and Nagar Haveli',  'DH'),
    ('Daman and Diu',           'DH'),
    ('Andaman',                 'AN'),
    ('Nicobar',                 'AN'),
    ('Telengana',               'TG'),   -- misspelling
    ('Uttar Pradesh UP',        'UP')
) AS a(alias, code)
JOIN config.states s ON s.state_code = a.code
ON CONFLICT ON CONSTRAINT pk_state_aliases DO NOTHING;

-- ── The resolver ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION config.fn_resolve_state(p_text text)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        -- 1. official name
        (SELECT s.state_id FROM config.states s
          WHERE config.fn_norm_state(s.name) = config.fn_norm_state(p_text)
          LIMIT 1),
        -- 2. ISO subdivision code
        (SELECT s.state_id FROM config.states s
          WHERE lower(s.state_code) = config.fn_norm_state(p_text)
          LIMIT 1),
        -- 3. alias
        (SELECT a.state_id FROM config.state_aliases a
          WHERE a.alias = config.fn_norm_state(p_text)
          LIMIT 1)
    );
$$;

COMMENT ON FUNCTION config.fn_resolve_state(text) IS
    'Free-text state -> config.states.state_id (name, ISO code, then config.state_aliases). NULL when it cannot be resolved — callers should surface that rather than guess.';

-- ── Backfill core.school_addresses ─────────────────────────────────────────
-- Sets the id AND rewrites the stored text to the canonical name, because the
-- varchar column is still what the list filter and every report read.
UPDATE core.school_addresses a
SET state_id   = s.state_id,
    country_id = COALESCE(a.country_id, s.country_id),
    state      = s.name,
    updated_at = NOW()
FROM config.states s
WHERE a.state_id IS NULL
  AND s.state_id = config.fn_resolve_state(a.state);

-- District, now that more rows have a state to scope the lookup by.
UPDATE core.school_addresses a
SET district_id = d.district_id,
    updated_at  = NOW()
FROM config.districts d
WHERE a.district_id IS NULL
  AND a.state_id = d.state_id
  AND config.fn_norm_state(a.district) = config.fn_norm_state(d.name);

-- ── Canonicalise the TEXT on every already-linked row ──────────────────────
-- geo_master.sql's original backfill matched case-insensitively, so rows can hold
-- the right state_id next to text like 'haryana' or 'delhi'. The varchar is what
-- the school-list filter and every report still read, so 'haryana' and 'Haryana'
-- would keep splitting one state into two buckets. Rewrite text from the master.
UPDATE core.school_addresses a
SET state      = s.name,
    updated_at = NOW()
FROM config.states s
WHERE a.state_id = s.state_id
  AND a.state IS DISTINCT FROM s.name;

UPDATE core.school_addresses a
SET district   = d.name,
    updated_at = NOW()
FROM config.districts d
WHERE a.district_id = d.district_id
  AND a.district IS DISTINCT FROM d.name;

-- What is left is genuinely unrecognisable ('TEST', 'Haryanafff') and needs a
-- human, not a guess:
--   SELECT school_address_id, school_id, state, city FROM core.school_addresses WHERE state_id IS NULL;
