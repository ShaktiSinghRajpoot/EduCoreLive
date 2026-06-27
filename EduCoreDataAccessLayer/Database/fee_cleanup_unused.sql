-- ============================================================================
-- Fee cleanup — drop procs orphaned by the Fee Collection counter redesign.
--
-- Verified unused (no C# caller, no SQL caller) as of 2026-06-21:
--   1. sp_fee_payment_collect (11-arg, pre-extras overload) — the live service
--      always passes p_extras, resolving to the 12-arg proc; the 11-arg is dead
--      and a name-resolution hazard (two overloads of the same name).
--   2. sp_fee_payment_record (lump-sum, oldest-first) — admission "collect now"
--      moved to the itemised sp_fee_payment_collect (CollectPaymentAsync); the
--      C# RecordPaymentAsync wrapper has no callers and is removed alongside.
--
-- KEPT (still in use): sp_fee_payment_collect (12-arg), sp_registration_fee_record
-- (registration/enquiry flow), and all other fee procs/tables.
--
-- Target DB: PostgreSQL (educore). Safe to re-run (IF EXISTS).
-- ============================================================================

-- 1. Stale 11-arg collect overload (no p_extras)
DROP PROCEDURE IF EXISTS core.sp_fee_payment_collect(
    integer, integer, integer, integer, jsonb,
    character varying, character varying, character varying, date, character varying, refcursor);

-- 2. Orphaned lump-sum payment proc
DROP PROCEDURE IF EXISTS core.sp_fee_payment_record(
    integer, integer, integer, integer, numeric,
    character varying, character varying, character varying, date, character varying, refcursor);
