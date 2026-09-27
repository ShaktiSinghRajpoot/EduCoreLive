-- ============================================================================
-- Put the database on India time.
--
-- THE BUG: the app is hosted on a server whose clock is UTC, and PostgreSQL was
-- left on Etc/UTC with it. Every CURRENT_DATE, now() and CURRENT_TIMESTAMP in
-- the procedures -- 426 of them -- therefore answered in UTC. Between midnight
-- and 5:30 am India time, the UTC date is still YESTERDAY:
--
--     collected   28 Sep 03:42 IST   =   27 Sep 22:12 UTC
--     stored as   payment_date = 2026-09-27
--     Day Close   asks for 28 Sep    ->  nothing, on a day with 13 receipts
--
-- It is not only Day Close. A receipt printed at 2 am carries yesterday's date,
-- a fee register misses the row, and an admission made at 1 am is dated a day
-- early. Every date in the system was quietly wrong for five and a half hours
-- out of every twenty-four.
--
-- THE FIX: set the database's timezone once. All 426 call sites are corrected
-- by it, and no procedure has to be touched. The app does the same on its side
-- through Dates.Now / Dates.Today (EduCoreDataAccessLayer/Helpers/Dates.cs), so
-- both ends read one clock -- the school's.
--
-- NOTE: ALTER DATABASE takes effect for NEW connections, so the app has to be
-- restarted (a deploy does it) before it sees the change.
--
-- Safe to re-run: the setting is idempotent, and the one-off correction below
-- is guarded by a mark so it can never be applied twice.
-- ============================================================================

-- -- 0. was this database on UTC? -------------------------------------------
-- Asked BEFORE the setting is changed, because the correction in step 3 must
-- only touch rows that were genuinely written in UTC. The developer machine was
-- already on Asia/Calcutta and never had this bug -- running the shift there
-- would push perfectly good timestamps five and a half hours into the future.
-- The answer is parked here for step 3 to read.
CREATE TEMP TABLE _tz_before AS
SELECT EXTRACT(TIMEZONE FROM now())::int AS offset_seconds,
       current_setting('TimeZone')       AS name;

-- -- 1. the setting ---------------------------------------------------------
DO $tz$
DECLARE
    v_name text;
BEGIN
    SELECT name INTO v_name FROM _tz_before;
    EXECUTE format('ALTER DATABASE %I SET TimeZone = %L', current_database(), 'Asia/Kolkata');
    RAISE NOTICE 'Database % moved from % to Asia/Kolkata. Restart the app so new connections pick it up.',
                 current_database(), v_name;
END
$tz$;

-- This script's own session, so the correction below reads India time too.
SET TimeZone = 'Asia/Kolkata';

-- -- 2. a record of one-off data corrections ---------------------------------
-- There was no migration table. This is the smallest thing that stops a
-- one-shot data fix from running a second time and shifting the same rows again.
CREATE TABLE IF NOT EXISTS core.schema_marks (
    mark       varchar(100) PRIMARY KEY,
    applied_at timestamptz  NOT NULL DEFAULT now(),
    note       text
);

-- -- 3. correct the payments taken while the server was on UTC --------------
-- Only core.fee_payments needs this. Its created_at is "timestamp without time
-- zone" and its payment_date is text, so both froze the UTC wall clock at the
-- moment of writing. cancelled_at and refunded_at are "timestamp with time
-- zone" -- those recorded a real instant and now simply read in India time, so
-- they need nothing.
DO $fix$
DECLARE
    v_rows       integer;
    v_was_utc    boolean;
    v_old_name   text;
BEGIN
    IF EXISTS (SELECT 1 FROM core.schema_marks WHERE mark = 'fee_payments_utc_to_ist') THEN
        RAISE NOTICE 'Payments were already corrected -- nothing to do.';
        RETURN;
    END IF;

    SELECT offset_seconds <> 19800, name INTO v_was_utc, v_old_name FROM _tz_before;

    -- Already on India time before this script ran, so the stored wall clock is
    -- already the school's -- there is nothing to shift. Record the mark anyway,
    -- so a later re-run cannot decide otherwise once the setting has changed.
    IF NOT v_was_utc THEN
        INSERT INTO core.schema_marks (mark, note)
        VALUES ('fee_payments_utc_to_ist',
                format('No shift needed: this database was already on %s (+05:30).', v_old_name));
        RAISE NOTICE 'Database was already on % -- payments left untouched.', v_old_name;
        RETURN;
    END IF;

    UPDATE core.fee_payments
    SET created_at   =  created_at + INTERVAL '5 hours 30 minutes',
        payment_date = (created_at + INTERVAL '5 hours 30 minutes')::date::text;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    INSERT INTO core.schema_marks (mark, note)
    VALUES ('fee_payments_utc_to_ist',
            format('Moved %s payment(s) from UTC wall clock to India time.', v_rows));

    RAISE NOTICE 'Corrected % payment(s) that were stamped in UTC.', v_rows;
END
$fix$;
