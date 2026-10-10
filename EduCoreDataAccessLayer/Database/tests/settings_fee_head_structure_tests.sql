-- ============================================================================
-- Fee Head master + Fee Structure test suite.
--
-- The two screens behind /ERP/SchoolSettings/FeeHead and /FeeStructure. A fee
-- head is the name every ledger row is keyed on, and a class structure is what
-- an admission turns into a year of dues, so the rules worth testing are the
-- ones that decide what a parent is billed and what happens to money already
-- taken when a setting changes.
--
-- The story the suite walks through (Sunrise Public School, session = the
-- school's current one):
--   * heads: Tuition (monthly), Admission Fee (one time, at admission), Caution
--     Money (refundable deposit), Transport (optional), Annual Charges
--     (quarterly), Activity (half yearly), Exam Fee (yearly), Registration;
--   * a structure for one class at Rs 2,500/month tuition, copied to a second
--     class and to next session;
--   * students admitted at session start and mid-session, billed from it;
--   * tuition revised mid-year after a payment; a head renamed, deactivated,
--     re-activated; heads deleted with and without money against them.
--
-- settings_tests.sql section C already covers: blank name, create, same-name
-- upsert, padded-name upsert, refundable round trip, cascade on an unpaid head,
-- platform-scope save. This file goes deeper and does not repeat those.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f settings_fee_head_structure_tests.sql
--
-- COVERS
--   A. Fee head - save and read back every field
--   B. Fee head - validation
--   C. Fee head - duplicates, case, whitespace, rename
--   D. Fee head - active / inactive toggle
--   E. Fee head - the paged list (search, cycle filter, sort, paging, tiles)
--   F. Fee structure - save and read back, rollups, multi-class, next session
--   G. Fee structure - edit, idempotent re-save, delete, revive
--   H. Fee structure - validation
--   I. Downstream - ledger generation, frozen ledgers, head edits vs structures
--   J. Fee head delete - guards and cascade
--   K. Scope and cross-school isolation
--
-- History: the first run (2026-10-10) failed 12 checks, all app bugs, since
-- fixed in fee_head_identity.sql, fee_structure_manage.sql, fee_head_list.sql
-- and fee_head_cascade_delete.sql:
--   I21  a rename rewrote OTHER schools' receipt lines (no tenant filter)
--   H7/H8/H9  structure save trusted the posted head id / name / cycle
--   I15  changing a head's cycle never reached saved structures
--   H3   a negative structure amount was accepted
--   B9   cycle stored as typed (" monthly "), B10 fee type not validated
--   H4/H6 blank class / session accepted, H13 rollups drifted from details
--   E12  list search not trimmed
-- Added with the fixes: B13-B14 (same name at another collection point), E13
-- (search is literal), I15b-c (rollups follow a cycle change), J7b-c (delete
-- recomputes from live structure lines only).
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 60), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- ── Small wrappers so each check reads as one line ─────────────────────────
-- Every wrapper passes a NULL refcursor, so PL/pgSQL names the portal itself and
-- no two calls collide on a cursor name inside the one transaction.

-- SaveFeeHead -> 'OK: <message>' or 'NO: <message>'. A RAISE propagates.
CREATE OR REPLACE FUNCTION pg_temp.fh(p_t int, p_s int, p_id int, p_name text, p_freq text, p_amt numeric,
                                      p_type text DEFAULT 'Mandatory', p_group text DEFAULT 'Academic',
                                      p_cp text DEFAULT 'Recurring', p_ref boolean DEFAULT FALSE)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; v_ok boolean; v_msg text;
BEGIN
    CALL core.sp_school_admin_fee_head_manage('SaveFeeHead', p_t, p_s, 39, p_id, p_name, p_freq, p_amt,
                                              p_type, p_group, p_cp, p_ref, c);
    FETCH c INTO v_ok, v_msg; CLOSE c;
    RETURN CASE WHEN v_ok THEN 'OK: ' ELSE 'NO: ' END || COALESCE(v_msg, '');
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fh_toggle(p_t int, p_s int, p_id int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; v_ok boolean; v_msg text;
BEGIN
    CALL core.sp_school_admin_fee_head_manage('ToggleFeeHeadStatus', p_t, p_s, 39, p_id, p_result => c);
    FETCH c INTO v_ok, v_msg; CLOSE c;
    RETURN CASE WHEN v_ok THEN 'OK: ' ELSE 'NO: ' END || COALESCE(v_msg, '');
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fh_del(p_t int, p_s int, p_id int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; v_ok boolean; v_msg text;
BEGIN
    CALL core.sp_fee_head_delete_cascade(p_t, p_s, 39, p_id, c);
    FETCH c INTO v_ok, v_msg; CLOSE c;
    RETURN CASE WHEN v_ok THEN 'OK: ' ELSE 'NO: ' END || COALESCE(v_msg, '');
END $$;

-- Live head id in the fixture school, by name (case-insensitive, like the index).
CREATE OR REPLACE FUNCTION pg_temp.fid(p_name text)
RETURNS int LANGUAGE sql AS $$
    SELECT fee_head_id FROM core.school_fee_heads
     WHERE tenant_id = 24 AND school_id = 34 AND COALESCE(is_deleted, FALSE) = FALSE
       AND lower(fee_head_name) = lower(p_name)
$$;

-- One structure line exactly as the Fee Structure page posts it: the hidden
-- inputs carry the master's id, name and cycle; only the amount is typed.
CREATE OR REPLACE FUNCTION pg_temp.d(p_id int, p_amt numeric)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('feeHeadId', fee_head_id, 'feeHeadName', fee_head_name,
                              'frequency', frequency, 'amount', p_amt)
      FROM core.school_fee_heads WHERE fee_head_id = p_id
$$;

CREATE OR REPLACE FUNCTION pg_temp.fs(p_t int, p_s int, p_class text, p_year text, p_details jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; v_ok boolean; v_msg text;
BEGIN
    CALL core.sp_school_admin_fee_structure_manage('SaveFeeStructure', p_t, p_s, 39, 0,
                                                   p_class, p_year, p_details, c);
    FETCH c INTO v_ok, v_msg; CLOSE c;
    RETURN CASE WHEN v_ok THEN 'OK: ' ELSE 'NO: ' END || COALESCE(v_msg, '');
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fs_del(p_t int, p_s int, p_id int)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; v_ok boolean; v_msg text;
BEGIN
    CALL core.sp_school_admin_fee_structure_manage('DeleteFeeStructure', p_t, p_s, 39, p_id,
                                                   NULL, NULL, NULL, c);
    FETCH c INTO v_ok, v_msg; CLOSE c;
    RETURN CASE WHEN v_ok THEN 'OK: ' ELSE 'NO: ' END || COALESCE(v_msg, '');
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fsid(p_class text, p_year text)
RETURNS int LANGUAGE sql AS $$
    SELECT fee_structure_id FROM core.school_fee_structures
     WHERE tenant_id = 24 AND school_id = 34 AND class_name = p_class AND academic_year = p_year
$$;

-- GetFeeStructure, as the Saved Structures table reads it.
CREATE OR REPLACE FUNCTION pg_temp.fs_list(p_t int, p_s int)
RETURNS TABLE(o_id int, o_class text, o_year text, o_monthly numeric, o_annual numeric,
              o_heads int, o_names text)
LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    CALL core.sp_school_admin_fee_structure_manage('GetFeeStructure', p_t, p_s, 39, p_result => c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        o_id := r.fee_structure_id; o_class := r.class_name; o_year := r.academic_year;
        o_monthly := r.monthly_total; o_annual := r.annual_total;
        o_heads := r.head_count; o_names := r.fee_head_names;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- GetFeeStructureDetails, as the edit button and the admission form read it.
CREATE OR REPLACE FUNCTION pg_temp.fs_det(p_t int, p_s int, p_class text, p_year text)
RETURNS TABLE(o_head int, o_name text, o_freq text, o_amt numeric)
LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    CALL core.sp_school_admin_fee_structure_manage('GetFeeStructureDetails', p_t, p_s, 39, 0,
                                                   p_class, p_year, NULL, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        o_head := r.fee_head_id; o_name := r.fee_head_name; o_freq := r.frequency; o_amt := r.amount;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- GetFeeHead (the cached master list) and GetFeeHeadById (the edit button).
CREATE OR REPLACE FUNCTION pg_temp.fh_get(p_t int, p_s int)
RETURNS TABLE(o_id int, o_name text, o_active boolean)
LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    CALL core.sp_school_admin_fee_head_manage('GetFeeHead', p_t, p_s, 39, p_result => c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        o_id := r.fee_head_id; o_name := r.fee_head_name; o_active := r.is_active;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fh_byid(p_t int, p_s int, p_id int)
RETURNS TABLE(o_id int, o_name text, o_freq text, o_amt numeric, o_type text, o_group text,
              o_cp text, o_ref boolean, o_active boolean)
LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record;
BEGIN
    CALL core.sp_school_admin_fee_head_manage('GetFeeHeadById', p_t, p_s, 39, p_id, p_result => c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        o_id := r.fee_head_id; o_name := r.fee_head_name; o_freq := r.frequency; o_amt := r.default_amount;
        o_type := r.fee_type; o_group := r.fee_group; o_cp := r.collection_point;
        o_ref := r.is_refundable; o_active := r.is_active;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- sp_fee_head_list, the server-side paged grid on the Fee Head page.
CREATE OR REPLACE FUNCTION pg_temp.fl(p_t int, p_s int, p_search text, p_freq text,
                                      p_page int, p_size int, p_sort text, p_dir text)
RETURNS TABLE(o_rn int, o_name text, o_amt numeric, o_freq text, o_active boolean,
              o_total int, o_mand int, o_opt int)
LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record; i int := 0;
BEGIN
    CALL core.sp_fee_head_list(p_t, p_s, 39, p_search, p_freq, p_page, p_size, p_sort, p_dir, c);
    LOOP
        FETCH c INTO r; EXIT WHEN NOT FOUND;
        i := i + 1;
        o_rn := i; o_name := r.fee_head_name; o_amt := r.default_amount; o_freq := r.frequency;
        o_active := r.is_active; o_total := r.total_count;
        o_mand := r.mandatory_count; o_opt := r.optional_count;
        RETURN NEXT;
    END LOOP;
    CLOSE c;
END $$;

-- The fee plan an admission sends, built from a saved class structure the way
-- AdmissionController.GetFeeStructure hands it to the form.
CREATE OR REPLACE FUNCTION pg_temp.plan(p_class text, p_year text)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_agg(jsonb_build_object('feeHeadId', d.fee_head_id, 'feeHeadName', d.fee_head_name,
                                        'frequency', d.frequency, 'amount', d.amount)
                     ORDER BY d.fee_head_name)
      FROM core.school_fee_structure_details d
      JOIN core.school_fee_structures s ON s.fee_structure_id = d.fee_structure_id
     WHERE s.tenant_id = 24 AND s.school_id = 34 AND s.class_name = p_class
       AND s.academic_year = p_year AND COALESCE(s.is_deleted, FALSE) = FALSE
       AND COALESCE(d.is_deleted, FALSE) = FALSE
$$;

CREATE OR REPLACE FUNCTION pg_temp.admit(p_no text, p_name text, p_class text, p_sec text,
                                         p_year text, p_date date, p_plan jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE c refcursor; v_sid int;
BEGIN
    CALL core.sp_admission_manage('SaveAdmission', 24, 34, 39, NULL,
         p_no, NULL, p_name, 'Female', DATE '2016-05-05',
         p_class, p_sec, p_year, p_date,
         p_fee_plan_json => p_plan, p_result => c);
    CLOSE c;
    SELECT student_id INTO v_sid FROM core.students
     WHERE tenant_id = 24 AND school_id = 34 AND admission_no = p_no;
    RETURN v_sid;
END $$;

-- Collect against ledger rows; returns the receipt number.
CREATE OR REPLACE FUNCTION pg_temp.collect(p_sid int, p_items jsonb, p_year text,
                                           p_dtype text DEFAULT NULL, p_dval numeric DEFAULT 0,
                                           p_dreason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; k_ok boolean; k_msg text; k_rcpt text; k_amt numeric;
BEGIN
    CALL core.sp_fee_payment_collect(24, 34, 39, p_sid, p_items, '[]'::jsonb, 'Cash', NULL, NULL,
         CURRENT_DATE, p_year, p_dtype, p_dval, p_dreason, NULL, 0, c);
    FETCH c INTO k_ok, k_msg, k_rcpt, k_amt; CLOSE c;
    IF NOT COALESCE(k_ok, FALSE) THEN
        RAISE EXCEPTION 'collect failed: %', k_msg;
    END IF;
    RETURN k_rcpt;
END $$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;
    c_ot     CONSTANT integer := 23;   -- the other school, for isolation checks
    c_os     CONSTANT integer := 33;

    v_year   varchar;
    v_yearid integer;
    v_start  date;
    v_end    date;
    v_months integer;
    v_next   varchar := 'ZZ 2027-28';   -- "next session" label for the copy case
    v_c1 varchar; v_c2 varchar; v_c3 varchar;
    v_s1 varchar; v_s2 varchar;

    c     refcursor;
    v_n   integer;
    v_m   integer;
    v_txt text;
    v_msg text;
    v_dec numeric;
    v_dec2 numeric;
    v_b   boolean;
    v_ts  timestamp;
    r     record;

    -- head ids
    h_tui int; h_adm int; h_cau int; h_tra int; h_ann int; h_act int; h_exm int; h_reg int;
    h_free int;
    v_fs1 int; v_fs2 int; v_fsn int;
    v_det int;
    v_sid1 int; v_sid2 int; v_sid3 int;
    v_lid int;
    v_rcpt text;
    v_pay int;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= FEE HEAD + FEE STRUCTURE TESTS =========';

    SELECT academic_year_id, academic_year_name, start_date, end_date
      INTO v_yearid, v_year, v_start, v_end
    FROM academic.academic_years
    WHERE tenant_id = c_tenant AND school_id = c_school
      AND COALESCE(is_current, FALSE) AND COALESCE(is_deleted, FALSE) = FALSE
    LIMIT 1;

    -- Three classes that have no structure yet this session, so nothing real is
    -- overwritten (even inside a rollback, a clean slate keeps the numbers exact).
    SELECT array_agg(class_name ORDER BY display_order) FILTER (WHERE rn <= 3) INTO STRICT v_txt
      FROM (SELECT ac.class_name, ac.display_order,
                   ROW_NUMBER() OVER (ORDER BY ac.display_order) AS rn
              FROM academic.academic_classes ac
             WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school
               AND ac.academic_year_id = v_yearid AND COALESCE(ac.is_deleted, FALSE) = FALSE
               AND NOT EXISTS (SELECT 1 FROM core.school_fee_structures fs
                                WHERE fs.tenant_id = c_tenant AND fs.school_id = c_school
                                  AND fs.class_name = ac.class_name AND fs.academic_year = v_year
                                  AND COALESCE(fs.is_deleted, FALSE) = FALSE)) x;
    v_c1 := (v_txt::text[])[1]; v_c2 := (v_txt::text[])[2]; v_c3 := (v_txt::text[])[3];

    SELECT s.section_name INTO v_s1 FROM academic.academic_class_sections s
      JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school AND ac.academic_year_id = v_yearid
       AND ac.class_name = v_c1 AND COALESCE(s.is_deleted, FALSE) = FALSE LIMIT 1;
    SELECT s.section_name INTO v_s2 FROM academic.academic_class_sections s
      JOIN academic.academic_classes ac ON ac.academic_class_id = s.academic_class_id
     WHERE ac.tenant_id = c_tenant AND ac.school_id = c_school AND ac.academic_year_id = v_yearid
       AND ac.class_name = v_c2 AND COALESCE(s.is_deleted, FALSE) = FALSE LIMIT 1;

    v_months := (EXTRACT(YEAR FROM v_end) * 12 + EXTRACT(MONTH FROM v_end))
              - (EXTRACT(YEAR FROM v_start) * 12 + EXTRACT(MONTH FROM v_start)) + 1;

    IF v_year IS NULL OR v_c3 IS NULL OR v_s1 IS NULL OR v_s2 IS NULL OR v_months <> 12 THEN
        RAISE EXCEPTION 'Fixture missing: school % needs a current 12-month session and 3 classes with sections and no fee structure.', c_school;
    END IF;
    RAISE NOTICE 'fixture: session=% (% .. %)  classes=% / % / %', v_year, v_start, v_end, v_c1, v_c2, v_c3;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Fee head: save and read back every field -----------';

    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Tuition', 'Monthly', 2500, 'Mandatory', 'Academic', 'Recurring', FALSE);
    h_tui := pg_temp.fid('ZZ Tuition');
    PERFORM pg_temp.chk('A1 Tuition (monthly, 2,500) is created', v_msg LIKE 'OK:%' AND h_tui IS NOT NULL, v_msg);

    SELECT * INTO r FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    PERFORM pg_temp.chk('A2 name stored exactly', r.fee_head_name = 'ZZ Tuition', r.fee_head_name);
    PERFORM pg_temp.chk('A2b billing cycle stored', r.frequency = 'Monthly', r.frequency);
    PERFORM pg_temp.chk_eq('A2c default amount stored', r.default_amount, 2500);
    PERFORM pg_temp.chk('A2d fee type stored', r.fee_type = 'Mandatory', r.fee_type);
    PERFORM pg_temp.chk('A2e fee group stored', r.fee_group = 'Academic', r.fee_group);
    PERFORM pg_temp.chk('A2f collection point stored', r.collection_point = 'Recurring', r.collection_point);
    PERFORM pg_temp.chk('A2g not refundable', r.is_refundable = FALSE, r.is_refundable::text);
    PERFORM pg_temp.chk('A2h new head is active and not deleted',
                        r.is_active AND NOT r.is_deleted, format('active=%s deleted=%s', r.is_active, r.is_deleted));
    PERFORM pg_temp.chk('A2i audit: created_by is the acting user', r.created_by = c_user,
                        format('created_by=%s', r.created_by));

    -- The edit button reads through GetFeeHeadById; every field must come back.
    SELECT * INTO r FROM pg_temp.fh_byid(c_tenant, c_school, h_tui);
    PERFORM pg_temp.chk('A3 GetFeeHeadById returns every field',
                        r.o_name = 'ZZ Tuition' AND r.o_freq = 'Monthly' AND r.o_amt = 2500
                        AND r.o_type = 'Mandatory' AND r.o_group = 'Academic' AND r.o_cp = 'Recurring'
                        AND r.o_ref = FALSE AND r.o_active,
                        format('%s/%s/%s/%s/%s/%s/%s/%s', r.o_name, r.o_freq, r.o_amt, r.o_type,
                               r.o_group, r.o_cp, r.o_ref, r.o_active));

    -- The rest of Sunrise's heads, one per cycle / collection point.
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Admission Fee', 'One Time', 15000, 'Mandatory', 'Academic', 'Admission', FALSE);
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Caution Money', 'One Time', 5000, 'Mandatory', 'Academic', 'Admission', TRUE);
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Transport', 'Monthly', 1200, 'Optional', 'Transport', 'Recurring', FALSE);
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Annual Charges', 'Quarterly', 1800, 'Mandatory', 'Academic', 'Recurring', FALSE);
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Activity', 'Half Yearly', 3000, 'Optional', 'Optional Services', 'Recurring', FALSE);
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Exam Fee', 'Yearly', 2000, 'Mandatory', 'Academic', 'Recurring', FALSE);
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Registration', 'One Time', 500, 'Mandatory', 'Academic', 'Registration', FALSE);
    h_adm := pg_temp.fid('ZZ Admission Fee'); h_cau := pg_temp.fid('ZZ Caution Money');
    h_tra := pg_temp.fid('ZZ Transport');     h_ann := pg_temp.fid('ZZ Annual Charges');
    h_act := pg_temp.fid('ZZ Activity');      h_exm := pg_temp.fid('ZZ Exam Fee');
    h_reg := pg_temp.fid('ZZ Registration');

    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name LIKE 'ZZ %'
       AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('A4 all eight Sunrise heads exist', v_n, 8);

    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE fee_head_id IN (h_tui, h_adm, h_cau, h_tra, h_ann, h_act, h_exm, h_reg)
       AND frequency IN ('One Time','Monthly','Quarterly','Half Yearly','Yearly');
    PERFORM pg_temp.chk_eq('A5 each of the five cycles is accepted', v_n, 8);

    SELECT COUNT(*) INTO v_n FROM pg_temp.fh_get(c_tenant, c_school) WHERE o_name LIKE 'ZZ %';
    PERFORM pg_temp.chk_eq('A6 GetFeeHead (master list) returns all eight', v_n, 8);

    SELECT collection_point || '/' || is_refundable INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_cau;
    PERFORM pg_temp.chk('A7 Caution Money: Admission point + refundable', v_txt = 'Admission/true', v_txt);

    SELECT collection_point INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_reg;
    PERFORM pg_temp.chk('A8 Registration point round-trips', v_txt = 'Registration', v_txt);

    -- Edit in place: Transport becomes mandatory at 1,300.
    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ Transport', 'Monthly', 1300, 'Mandatory', 'Transport', 'Recurring', FALSE);
    SELECT * INTO r FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('A9 edit updates amount and type in place',
                        r.default_amount = 1300 AND r.fee_type = 'Mandatory' AND pg_temp.fid('ZZ Transport') = h_tra,
                        format('%s / %s / id %s', r.default_amount, r.fee_type, pg_temp.fid('ZZ Transport')));
    PERFORM pg_temp.chk('A9b edit stamps updated_by / updated_at',
                        r.updated_by = c_user AND r.updated_at IS NOT NULL,
                        format('updated_by=%s at=%s', r.updated_by, r.updated_at));

    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Free Diary', 'One Time', 0, 'Optional', 'Academic', 'Admission', FALSE);
    h_free := pg_temp.fid('ZZ Free Diary');
    PERFORM pg_temp.chk('A10 a zero-amount head is allowed', v_msg LIKE 'OK:%' AND h_free IS NOT NULL, v_msg);

    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Paise', 'Monthly', 1234.56);
    SELECT default_amount INTO v_dec FROM core.school_fee_heads WHERE fee_head_id = pg_temp.fid('ZZ Paise');
    PERFORM pg_temp.chk_eq('A11 paise are kept exactly', v_dec, 1234.56);

    PERFORM pg_temp.fh(c_tenant, c_school, pg_temp.fid('ZZ Paise'), 'ZZ Paise', 'Monthly', 99.999);
    SELECT default_amount INTO v_dec FROM core.school_fee_heads WHERE fee_head_id = pg_temp.fid('ZZ Paise');
    PERFORM pg_temp.chk_eq('A12 a third decimal rounds to the paisa', v_dec, 100.00);

    PERFORM pg_temp.fh(c_tenant, c_school, pg_temp.fid('ZZ Paise'), 'ZZ Paise', 'Monthly', NULL);
    SELECT default_amount INTO v_dec FROM core.school_fee_heads WHERE fee_head_id = pg_temp.fid('ZZ Paise');
    PERFORM pg_temp.chk_eq('A13 a blank amount is stored as 0, not NULL', v_dec, 0);

    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Huge', 'Yearly', 9999999999.99);
    PERFORM pg_temp.chk('A14 the largest amount the column holds is accepted', v_msg LIKE 'OK:%', v_msg);

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Too Huge', 'Yearly', 10000000000);
        PERFORM pg_temp.chk('A15 an amount past the column limit is refused', FALSE, 'accepted: ' || v_msg);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A15 an amount past the column limit is refused', TRUE, SQLERRM);
    END;

    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ ' || repeat('x', 77), 'Yearly', 1);
    PERFORM pg_temp.chk('A16 an 80-character name (the form maxlength) is accepted', v_msg LIKE 'OK:%', left(v_msg, 40));

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ ' || repeat('y', 78), 'Yearly', 1);
        PERFORM pg_temp.chk('A17 an 81-character name is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A17 an 81-character name is refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Fee head: validation --------------------------------';

    SELECT COUNT(*) INTO v_m FROM core.school_fee_heads WHERE tenant_id = c_tenant AND school_id = c_school;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, NULL, 'Monthly', 100);
        PERFORM pg_temp.chk('B1 NULL name refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B1 NULL name refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Negative', 'Monthly', -0.01);
        PERFORM pg_temp.chk('B2 negative amount (-0.01) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B2 negative amount (-0.01) refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Weekly', 'Weekly', 100);
        PERFORM pg_temp.chk('B3 unknown cycle "Weekly" refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B3 unknown cycle "Weekly" refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ No Cycle', '', 100);
        PERFORM pg_temp.chk('B4 blank cycle refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B4 blank cycle refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Null Cycle', NULL, 100);
        PERFORM pg_temp.chk('B5 NULL cycle refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B5 NULL cycle refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Counter', 'One Time', 100, 'Mandatory', 'Academic', 'Counter');
        PERFORM pg_temp.chk('B6 unknown collection point refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B6 unknown collection point refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ No Type', 'Monthly', 100, NULL);
        PERFORM pg_temp.chk('B7 NULL fee type refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B7 NULL fee type refused', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk_eq('B8 refused saves left no row behind', v_n, v_m);

    -- The proc lower()s and trim()s the cycle to VALIDATE it, then stores what was
    -- typed. Every reader matches the cycle by exact text: the Fee Structure page
    -- files heads under "Monthly" etc. (FeeStructure.cshtml:218/228) and skips
    -- anything else -- which also leaves a hole in the FeeHeads[i] indexes, so MVC
    -- stops binding at the gap and drops every head after it on save.
    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Lower Cycle', ' monthly ', 100);
    SELECT frequency INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = pg_temp.fid('ZZ Lower Cycle');
    PERFORM pg_temp.chk('B9 cycle " monthly " is stored as "Monthly"', v_txt = 'Monthly',
                        format('stored as "%s"', v_txt));

    -- Mandatory / Optional drives the tiles and which heads the structure page
    -- pre-ticks. Anything else is silently neither.
    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Odd Type', 'Monthly', 100, 'Compulsory');
        PERFORM pg_temp.chk('B10 fee type other than Mandatory/Optional refused', FALSE,
                            'accepted and stored as "Compulsory"');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B10 fee type other than Mandatory/Optional refused', TRUE, SQLERRM);
    END;

    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Null Point', 'Monthly', 100, 'Optional', NULL, NULL);
    SELECT collection_point || '/' || fee_group INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = pg_temp.fid('ZZ Null Point');
    PERFORM pg_temp.chk('B11 NULL point/group default to Recurring/Academic', v_txt = 'Recurring/Academic', v_txt);

    v_msg := pg_temp.fh(c_tenant, c_school, 999999, 'ZZ Ghost', 'Monthly', 100);
    PERFORM pg_temp.chk('B12 editing an id that does not exist reports not found',
                        v_msg LIKE 'NO:%' AND pg_temp.fid('ZZ Ghost') IS NULL, v_msg);

    -- The create form upserts on the name, but only onto the same kind of
    -- charge. "ZZ Tuition" typed as an Admission-point charge (what the
    -- Admission Workflow fee cards send) must not turn Tuition into one.
    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, 0, ' zz tuition ', 'One Time', 999, 'Mandatory', 'Academic', 'Admission', TRUE);
        PERFORM pg_temp.chk('B13 same name at another collection point refused', FALSE, 'accepted: ' || v_msg);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('B13 same name at another collection point refused', SQLERRM LIKE '%already exists as a%', SQLERRM);
    END;
    SELECT frequency || '/' || default_amount || '/' || collection_point || '/' || is_refundable INTO v_txt
      FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    PERFORM pg_temp.chk('B14 ...and Tuition is untouched', v_txt = 'Monthly/2500.00/Recurring/false', v_txt);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Fee head: duplicates, case, whitespace, rename -------';

    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'zz tuition', 'Monthly', 2500);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND lower(fee_head_name) = 'zz tuition'
       AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C1 "zz tuition" does not create a second Tuition', v_n, 1);
    SELECT fee_head_name INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    PERFORM pg_temp.chk('C2 ...and the original casing is kept', v_txt = 'ZZ Tuition', v_txt);

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ Tuition', 'Monthly', 1300, 'Mandatory', 'Transport');
        PERFORM pg_temp.chk('C3 renaming Transport onto Tuition refused', FALSE, 'accepted: ' || v_msg);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C3 renaming Transport onto Tuition refused', SQLERRM LIKE '%already exists%', SQLERRM);
    END;
    SELECT fee_head_name INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('C4 ...and Transport keeps its name', v_txt = 'ZZ Transport', v_txt);

    BEGIN
        v_msg := pg_temp.fh(c_tenant, c_school, h_tra, '  ZZ TUITION ', 'Monthly', 1300, 'Mandatory', 'Transport');
        PERFORM pg_temp.chk('C5 rename onto a name differing by case/space refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C5 rename onto a name differing by case/space refused', TRUE, SQLERRM);
    END;

    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ TRANSPORT', 'Monthly', 1300, 'Mandatory', 'Transport');
    SELECT fee_head_name INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('C6 a head can change its own casing', v_txt = 'ZZ TRANSPORT', v_txt);

    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, '   ZZ Bus Fee   ', 'Monthly', 1300, 'Mandatory', 'Transport');
    SELECT fee_head_name INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('C7 a padded rename is stored trimmed', v_txt = 'ZZ Bus Fee', format('"%s"', v_txt));

    -- Re-saving exactly the same values twice changes nothing and never errors.
    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ Bus Fee', 'Monthly', 1300, 'Mandatory', 'Transport');
    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ Bus Fee', 'Monthly', 1300, 'Mandatory', 'Transport');
    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND lower(fee_head_name) = 'zz bus fee';
    PERFORM pg_temp.chk('C8 re-saving an unchanged head is idempotent', v_n = 1 AND v_msg LIKE 'OK:%',
                        format('%s row(s), %s', v_n, v_msg));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Fee head: active / inactive --------------------------';

    v_msg := pg_temp.fh_toggle(c_tenant, c_school, h_tra);
    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('D1 toggle switches an active head off', v_b = FALSE AND v_msg LIKE 'OK:%inactive%', v_msg);

    SELECT o_active INTO v_b FROM pg_temp.fh_get(c_tenant, c_school) WHERE o_id = h_tra;
    PERFORM pg_temp.chk('D2 master list still returns it, flagged inactive', v_b = FALSE,
                        format('is_active=%s', v_b));

    SELECT o_active INTO v_b FROM pg_temp.fl(c_tenant, c_school, 'ZZ Bus', NULL, 1, 10, NULL, 'asc');
    PERFORM pg_temp.chk('D3 the paged grid lists it with is_active=false', v_b = FALSE,
                        format('is_active=%s', v_b));

    SELECT o_active INTO v_b FROM pg_temp.fh_byid(c_tenant, c_school, h_tra);
    PERFORM pg_temp.chk('D4 GetFeeHeadById still finds an inactive head', v_b = FALSE, format('is_active=%s', v_b));

    v_msg := pg_temp.fh_toggle(c_tenant, c_school, h_tra);
    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('D5 toggling again re-activates it', v_b AND v_msg LIKE 'OK:%active again%', v_msg);

    v_msg := pg_temp.fh_toggle(c_tenant, c_school, 999999);
    PERFORM pg_temp.chk('D6 toggling an unknown id reports not found', v_msg LIKE 'NO:%', v_msg);

    -- Editing an inactive head must not quietly switch it back on.
    PERFORM pg_temp.fh_toggle(c_tenant, c_school, h_tra);
    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ Bus Fee', 'Monthly', 1350, 'Mandatory', 'Transport');
    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('D7 editing an inactive head keeps it inactive', v_b = FALSE, format('is_active=%s', v_b));

    -- By design the create form upserts on the name (settings_tests C4), and that
    -- upsert sets is_active = TRUE. So typing an inactive head's name into the
    -- create form switches it back on. Recorded here so the behaviour is visible.
    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Bus Fee', 'Monthly', 1350, 'Mandatory', 'Transport');
    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_tra;
    PERFORM pg_temp.chk('D8 create-form upsert on an inactive name revives it (by design)', v_b = TRUE,
                        format('is_active=%s', v_b));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Fee head: the paged list ------------------------------';

    SELECT COUNT(*) INTO v_m FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name ILIKE '%zz %'
       AND COALESCE(is_deleted, FALSE) = FALSE;

    SELECT COUNT(*), MAX(o_total) INTO v_n, v_dec FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 1, 200, NULL, 'asc');
    PERFORM pg_temp.chk('E1 search is case-insensitive and total_count is the full set',
                        v_n = v_m AND v_dec = v_m, format('rows=%s total=%s expected=%s', v_n, v_dec, v_m));

    SELECT COUNT(*), MAX(o_total) INTO v_n, v_dec FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 1, 3, NULL, 'asc');
    PERFORM pg_temp.chk('E2 page size 3 returns 3 rows but the full total',
                        v_n = 3 AND v_dec = v_m, format('rows=%s total=%s', v_n, v_dec));

    SELECT string_agg(o_name, '|' ORDER BY o_rn) INTO v_txt FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 2, 3, 'name', 'asc');
    SELECT string_agg(fee_head_name, '|' ORDER BY fee_head_name) INTO v_msg FROM (
        SELECT fee_head_name FROM core.school_fee_heads
         WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name ILIKE '%zz %'
           AND COALESCE(is_deleted, FALSE) = FALSE ORDER BY fee_head_name OFFSET 3 LIMIT 3) x;
    PERFORM pg_temp.chk('E3 page 2 is rows 4-6 of the sorted set', v_txt = v_msg, left(v_txt, 60));

    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 99, 10, NULL, 'asc');
    PERFORM pg_temp.chk_eq('E4 a page past the end is empty, not an error', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 0, 0, NULL, 'asc');
    PERFORM pg_temp.chk('E5 page 0 / size 0 clamp to page 1 / size 10', v_n = LEAST(10, v_m),
                        format('rows=%s', v_n));

    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, 'zz ', 'monthly', 1, 200, NULL, 'asc')
     WHERE o_freq <> 'Monthly';
    SELECT COUNT(*) INTO v_m FROM pg_temp.fl(c_tenant, c_school, 'zz ', 'monthly', 1, 200, NULL, 'asc');
    PERFORM pg_temp.chk('E6 cycle filter (any case) returns only that cycle', v_n = 0 AND v_m >= 2,
                        format('%s monthly rows, %s others', v_m, v_n));

    SELECT o_amt INTO v_dec FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 1, 1, 'amount', 'desc');
    SELECT MAX(default_amount) INTO v_dec2 FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name ILIKE '%zz %'
       AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('E7 sort by amount desc puts the largest first', v_dec, v_dec2);

    SELECT o_name INTO v_txt FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 1, 1, 'name', 'desc');
    SELECT MAX(fee_head_name) INTO v_msg FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name ILIKE '%zz %'
       AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('E8 sort by name desc', v_txt = v_msg, v_txt);

    BEGIN
        SELECT o_name INTO v_txt FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 1, 1, '1; DROP TABLE x', 'sideways');
        SELECT MIN(fee_head_name) INTO v_msg FROM core.school_fee_heads
         WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name ILIKE '%zz %'
           AND COALESCE(is_deleted, FALSE) = FALSE;
        PERFORM pg_temp.chk('E9 an unknown sort column falls back to name asc', v_txt = v_msg, v_txt);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E9 an unknown sort column falls back to name asc', FALSE, SQLERRM);
    END;

    SELECT MAX(o_mand), MAX(o_opt) INTO v_n, v_m FROM pg_temp.fl(c_tenant, c_school, 'zz ', NULL, 1, 2, NULL, 'asc');
    SELECT COUNT(*) FILTER (WHERE fee_type = 'Mandatory'), COUNT(*) FILTER (WHERE fee_type = 'Optional')
      INTO v_dec, v_dec2 FROM core.school_fee_heads
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name ILIKE '%zz %'
       AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('E10 Mandatory/Optional tiles count the whole filtered set',
                        v_n = v_dec AND v_m = v_dec2,
                        format('tiles %s/%s, actual %s/%s (page size 2)', v_n, v_m, v_dec, v_dec2));

    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, 'no such head qq', NULL, 1, 10, NULL, 'asc');
    PERFORM pg_temp.chk_eq('E11 a search with no match returns no rows', v_n, 0);

    -- A pasted search term often carries a trailing space. The proc checks
    -- TRIM(p_search) = '' but then matches the untrimmed text, and the controller
    -- passes Search through as-is.
    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, ' zz tuition ', NULL, 1, 10, NULL, 'asc');
    PERFORM pg_temp.chk('E12 search " zz tuition " (padded) still finds Tuition', v_n = 1,
                        format('%s row(s)', v_n));

    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, '%', NULL, 1, 200, NULL, 'asc');
    PERFORM pg_temp.chk_eq('E13 "%" is searched literally, not as a wildcard', v_n, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Fee structure: save and read back ---------------------';

    -- Class 1 for the session: tuition 2,500/month, annual charges quarterly,
    -- activity half-yearly, exam yearly, admission fee + caution money once.
    v_msg := pg_temp.fs(c_tenant, c_school, v_c1, v_year, jsonb_build_array(
                 pg_temp.d(h_tui, 2500), pg_temp.d(h_ann, 1800), pg_temp.d(h_act, 3000),
                 pg_temp.d(h_exm, 2000), pg_temp.d(h_adm, 15000), pg_temp.d(h_cau, 5000)));
    v_fs1 := pg_temp.fsid(v_c1, v_year);
    PERFORM pg_temp.chk('F1 structure for the class is saved', v_msg LIKE 'OK:%' AND v_fs1 IS NOT NULL, v_msg);

    SELECT * INTO r FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk_eq('F2 one-time total = admission + caution', r.one_time_total, 20000);
    PERFORM pg_temp.chk_eq('F2b monthly total', r.monthly_total, 2500);
    PERFORM pg_temp.chk_eq('F2c quarterly total', r.quarterly_total, 1800);
    PERFORM pg_temp.chk_eq('F2d half-yearly total', r.half_yearly_total, 3000);
    PERFORM pg_temp.chk_eq('F2e yearly total', r.yearly_total, 2000);
    -- 20000 + 2500x12 + 1800x4 + 3000x2 + 2000
    PERFORM pg_temp.chk_eq('F2f annual = OT + Mx12 + Qx4 + Hx2 + Y', r.annual_total, 65200);
    PERFORM pg_temp.chk('F2g active, not deleted, created_by = user',
                        r.is_active AND NOT r.is_deleted AND r.created_by = c_user,
                        format('active=%s deleted=%s by=%s', r.is_active, r.is_deleted, r.created_by));

    SELECT COUNT(*) INTO v_n FROM core.school_fee_structure_details
     WHERE fee_structure_id = v_fs1 AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('F3 six detail rows written', v_n, 6);

    SELECT COUNT(*) INTO v_n FROM core.school_fee_structure_details d
      JOIN core.school_fee_heads h ON h.fee_head_id = d.fee_head_id
     WHERE d.fee_structure_id = v_fs1 AND d.fee_head_name = h.fee_head_name AND d.frequency = h.frequency;
    PERFORM pg_temp.chk_eq('F4 every detail carries its head id, name and cycle', v_n, 6);

    SELECT amount INTO v_dec FROM core.school_fee_structure_details WHERE fee_structure_id = v_fs1 AND fee_head_id = h_tui;
    PERFORM pg_temp.chk_eq('F5 tuition amount is the typed 2,500', v_dec, 2500);

    SELECT * INTO r FROM pg_temp.fs_list(c_tenant, c_school) WHERE o_id = v_fs1;
    PERFORM pg_temp.chk('F6 Saved Structures lists it: 6 heads, annual 65,200',
                        r.o_heads = 6 AND r.o_annual = 65200 AND r.o_year = v_year,
                        format('heads=%s annual=%s year=%s', r.o_heads, r.o_annual, r.o_year));
    PERFORM pg_temp.chk('F7 head names listed alphabetically',
                        r.o_names = 'ZZ Activity, ZZ Admission Fee, ZZ Annual Charges, ZZ Caution Money, ZZ Exam Fee, ZZ Tuition',
                        r.o_names);

    SELECT COUNT(*), SUM(o_amt) INTO v_n, v_dec FROM pg_temp.fs_det(c_tenant, c_school, v_c1, v_year);
    PERFORM pg_temp.chk('F8 GetFeeStructureDetails returns the six lines',
                        v_n = 6 AND v_dec = 29300, format('%s lines, sum %s', v_n, v_dec));

    -- Same structure for a second class in one save (the page loops classes).
    v_msg := pg_temp.fs(c_tenant, c_school, v_c2, v_year, jsonb_build_array(
                 pg_temp.d(h_tui, 2500), pg_temp.d(h_ann, 1800), pg_temp.d(h_act, 3000),
                 pg_temp.d(h_exm, 2000), pg_temp.d(h_adm, 15000), pg_temp.d(h_cau, 5000)));
    v_fs2 := pg_temp.fsid(v_c2, v_year);
    PERFORM pg_temp.chk('F9 second class gets its own structure', v_fs2 IS NOT NULL AND v_fs2 <> v_fs1,
                        format('ids %s / %s', v_fs1, v_fs2));

    -- Copy to next session: same class, different year, separate record.
    v_msg := pg_temp.fs(c_tenant, c_school, v_c1, v_next, jsonb_build_array(
                 pg_temp.d(h_tui, 2700), pg_temp.d(h_adm, 15000)));
    v_fsn := pg_temp.fsid(v_c1, v_next);
    SELECT annual_total INTO v_dec FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk('F10 next session is a separate structure; this one untouched',
                        v_fsn IS NOT NULL AND v_fsn <> v_fs1 AND v_dec = 65200,
                        format('next id %s, this annual %s', v_fsn, v_dec));

    v_msg := pg_temp.fs(c_tenant, c_school, v_c3, v_year, jsonb_build_array(
                 pg_temp.d(h_free, 0), pg_temp.d(h_tui, 2500)));
    SELECT o_heads INTO v_n FROM pg_temp.fs_list(c_tenant, c_school) WHERE o_class = v_c3 AND o_year = v_year;
    PERFORM pg_temp.chk_eq('F11 a zero-amount head still counts as a head', v_n, 2);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- G. Fee structure: edit, re-save, delete ------------------';

    v_msg := pg_temp.fs(c_tenant, c_school, v_c1, v_year, jsonb_build_array(
                 pg_temp.d(h_tui, 2500), pg_temp.d(h_ann, 1800), pg_temp.d(h_act, 3000),
                 pg_temp.d(h_exm, 2000), pg_temp.d(h_adm, 15000), pg_temp.d(h_cau, 5000)));
    SELECT COUNT(*), COUNT(*) FILTER (WHERE COALESCE(is_deleted, FALSE) = FALSE) INTO v_n, v_m
      FROM core.school_fee_structure_details WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk('G1 identical re-save keeps the id and adds no rows',
                        pg_temp.fsid(v_c1, v_year) = v_fs1 AND v_n = 6 AND v_m = 6,
                        format('id %s, %s rows (%s live)', pg_temp.fsid(v_c1, v_year), v_n, v_m));
    SELECT COUNT(*) INTO v_n FROM core.school_fee_structures
     WHERE tenant_id = c_tenant AND school_id = c_school AND class_name = v_c1 AND academic_year = v_year;
    PERFORM pg_temp.chk_eq('G2 still exactly one header for class + session', v_n, 1);

    -- Mid-year revision: tuition up to 2,800 and Activity dropped.
    SELECT fee_structure_detail_id INTO v_det FROM core.school_fee_structure_details
     WHERE fee_structure_id = v_fs1 AND fee_head_id = h_act;
    v_msg := pg_temp.fs(c_tenant, c_school, v_c1, v_year, jsonb_build_array(
                 pg_temp.d(h_tui, 2800), pg_temp.d(h_ann, 1800),
                 pg_temp.d(h_exm, 2000), pg_temp.d(h_adm, 15000), pg_temp.d(h_cau, 5000)));
    SELECT * INTO r FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk('G3 edit recomputes the rollups',
                        r.monthly_total = 2800 AND r.half_yearly_total = 0 AND r.annual_total = 20000 + 33600 + 7200 + 2000,
                        format('monthly %s half %s annual %s', r.monthly_total, r.half_yearly_total, r.annual_total));
    PERFORM pg_temp.chk('G4 edit stamps updated_by / updated_at', r.updated_by = c_user AND r.updated_at IS NOT NULL,
                        format('by %s at %s', r.updated_by, r.updated_at));

    SELECT COALESCE(is_deleted, FALSE) AND NOT COALESCE(is_selected, TRUE) INTO v_b
      FROM core.school_fee_structure_details WHERE fee_structure_detail_id = v_det;
    PERFORM pg_temp.chk('G5 the dropped head is soft-deleted, not hard-deleted', v_b, format('soft-deleted=%s', v_b));

    SELECT COUNT(*) INTO v_n FROM pg_temp.fs_det(c_tenant, c_school, v_c1, v_year) WHERE o_head = h_act;
    PERFORM pg_temp.chk_eq('G6 ...and no longer comes back in the details', v_n, 0);
    SELECT o_heads INTO v_n FROM pg_temp.fs_list(c_tenant, c_school) WHERE o_id = v_fs1;
    PERFORM pg_temp.chk_eq('G7 head count drops to 5', v_n, 5);

    v_msg := pg_temp.fs(c_tenant, c_school, v_c1, v_year, jsonb_build_array(
                 pg_temp.d(h_tui, 2800), pg_temp.d(h_ann, 1800), pg_temp.d(h_act, 3200),
                 pg_temp.d(h_exm, 2000), pg_temp.d(h_adm, 15000), pg_temp.d(h_cau, 5000)));
    SELECT amount INTO v_dec FROM core.school_fee_structure_details
     WHERE fee_structure_detail_id = v_det AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('G8 re-adding the head revives the same row with the new amount', v_dec = 3200,
                        format('row %s amount %s', v_det, v_dec));

    SELECT monthly_total INTO v_dec FROM core.school_fee_structures WHERE fee_structure_id = v_fs2;
    PERFORM pg_temp.chk_eq('G9 editing one class leaves the other class alone', v_dec, 2500);

    -- Deactivating a head leaves it on structures already saved; the admission
    -- form filters it out by flag (AdmissionController.GetFeeStructure).
    PERFORM pg_temp.fh_toggle(c_tenant, c_school, h_exm);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fs_det(c_tenant, c_school, v_c1, v_year) WHERE o_head = h_exm;
    PERFORM pg_temp.chk_eq('G10 an inactive head stays on the saved structure', v_n, 1);
    PERFORM pg_temp.fh_toggle(c_tenant, c_school, h_exm);

    v_msg := pg_temp.fs_del(c_tenant, c_school, v_fs2);
    SELECT COALESCE(is_deleted, FALSE) AND NOT COALESCE(is_active, TRUE) INTO v_b
      FROM core.school_fee_structures WHERE fee_structure_id = v_fs2;
    PERFORM pg_temp.chk('G11 delete structure soft-deletes the header', v_msg LIKE 'OK:%' AND v_b, v_msg);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_structure_details
     WHERE fee_structure_id = v_fs2 AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('G12 ...and its details', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fs_list(c_tenant, c_school) WHERE o_id = v_fs2;
    PERFORM pg_temp.chk_eq('G13 a deleted structure is not listed', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fs_det(c_tenant, c_school, v_c2, v_year);
    PERFORM pg_temp.chk_eq('G14 ...nor offered to admission', v_n, 0);

    v_msg := pg_temp.fs_del(c_tenant, c_school, v_fs2);
    PERFORM pg_temp.chk('G15 deleting it again reports not found', v_msg LIKE 'NO:%', v_msg);

    v_msg := pg_temp.fs(c_tenant, c_school, v_c2, v_year, jsonb_build_array(pg_temp.d(h_tui, 2600)));
    SELECT COALESCE(is_deleted, FALSE), is_active, annual_total INTO v_b, v_txt, v_dec
      FROM core.school_fee_structures WHERE fee_structure_id = v_fs2;
    PERFORM pg_temp.chk('G16 saving a deleted class again revives it (same id)',
                        pg_temp.fsid(v_c2, v_year) = v_fs2 AND NOT v_b AND v_dec = 31200,
                        format('deleted=%s annual=%s', v_b, v_dec));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- H. Fee structure: validation -----------------------------';

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H1', NULL);
        PERFORM pg_temp.chk('H1 a save with no details (NULL) refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H1 a save with no details (NULL) refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H2', '[]'::jsonb);
        PERFORM pg_temp.chk('H2 a save with an empty list refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H2 a save with an empty list refused', TRUE, SQLERRM);
    END;

    -- The fee head master refuses a negative amount because it would be "written
    -- straight into every student's ledger". The structure amount is the one that
    -- actually reaches the ledger, and it has no such guard.
    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H3', jsonb_build_array(pg_temp.d(h_tui, -500)));
        SELECT annual_total INTO v_dec FROM core.school_fee_structures WHERE fee_structure_id = pg_temp.fsid(v_c3, 'ZZ H3');
        PERFORM pg_temp.chk('H3 a negative structure amount is refused', FALSE,
                            format('accepted, annual total %s', v_dec));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H3 a negative structure amount is refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, '', 'ZZ H4', jsonb_build_array(pg_temp.d(h_tui, 100)));
        PERFORM pg_temp.chk('H4 a blank class name is refused', FALSE, 'accepted: ' || v_msg);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H4 a blank class name is refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, NULL, 'ZZ H5', jsonb_build_array(pg_temp.d(h_tui, 100)));
        PERFORM pg_temp.chk('H5 a NULL class name is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H5 a NULL class name is refused', TRUE, SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, '   ', jsonb_build_array(pg_temp.d(h_tui, 100)));
        PERFORM pg_temp.chk('H6 a blank academic year is refused', FALSE, 'accepted: ' || v_msg);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H6 a blank academic year is refused', TRUE, SQLERRM);
    END;

    -- Another school's fee head id must not be attachable to our structure.
    DECLARE v_foreign int;
    BEGIN
        SELECT fee_head_id INTO v_foreign FROM core.school_fee_heads
         WHERE tenant_id = c_ot AND school_id = c_os AND COALESCE(is_deleted, FALSE) = FALSE LIMIT 1;
        BEGIN
            v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H7', jsonb_build_array(
                         jsonb_build_object('feeHeadId', v_foreign, 'feeHeadName', 'ZZ Foreign',
                                            'frequency', 'Monthly', 'amount', 100)));
            PERFORM pg_temp.chk('H7 a fee head id from another school is refused', FALSE,
                                format('accepted head %s of school %s', v_foreign, c_os));
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('H7 a fee head id from another school is refused', TRUE, SQLERRM);
        END;
    END;

    -- A deleted head must not be attachable either.
    DECLARE v_dead int;
    BEGIN
        PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Dead Head', 'Monthly', 10);
        v_dead := pg_temp.fid('ZZ Dead Head');
        PERFORM pg_temp.fh_del(c_tenant, c_school, v_dead);
        BEGIN
            v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H8', jsonb_build_array(
                         jsonb_build_object('feeHeadId', v_dead, 'feeHeadName', 'ZZ Dead Head',
                                            'frequency', 'Monthly', 'amount', 10)));
            PERFORM pg_temp.chk('H8 a deleted fee head is refused on a structure', FALSE, 'accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('H8 a deleted fee head is refused on a structure', TRUE, SQLERRM);
        END;
    END;

    -- The page posts the name and cycle in hidden inputs next to the id. The proc
    -- stores whatever comes in, so the structure can disagree with the master.
    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H9', jsonb_build_array(
                     jsonb_build_object('feeHeadId', h_tui, 'feeHeadName', 'Hacked Name',
                                        'frequency', 'Weekly', 'amount', 100)));
        SELECT fee_head_name || ' / ' || frequency INTO v_txt FROM core.school_fee_structure_details
         WHERE fee_structure_id = pg_temp.fsid(v_c3, 'ZZ H9') AND fee_head_id = h_tui;
        PERFORM pg_temp.chk('H9 detail name and cycle come from the master, not the post',
                            v_txt = 'ZZ Tuition / Monthly', format('stored "%s"', v_txt));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H9 detail name and cycle come from the master, not the post', TRUE,
                            'refused: ' || SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H10', jsonb_build_array(
                     pg_temp.d(h_tui, 100), pg_temp.d(h_tui, 200)));
        PERFORM pg_temp.chk('H10 the same head twice in one save is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H10 the same head twice in one save is refused', TRUE, SQLERRM);
    END;
    PERFORM pg_temp.chk('H11 ...and nothing of it was written', pg_temp.fsid(v_c3, 'ZZ H10') IS NULL,
                        format('header id %s', pg_temp.fsid(v_c3, 'ZZ H10')));

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H12', jsonb_build_array(
                     jsonb_build_object('feeHeadName', 'No Id', 'frequency', 'Monthly', 'amount', 10)));
        PERFORM pg_temp.chk('H12 a line with no fee head id is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H12 a line with no fee head id is refused', TRUE, SQLERRM);
    END;

    -- Rollups are computed from the posted numbers, the details are stored at two
    -- decimals. The proc's own comment says the totals "cannot drift from the
    -- stored details".
    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H13', jsonb_build_array(pg_temp.d(h_tui, 2500.555)));
        SELECT s.annual_total, d.amount * 12 INTO v_dec, v_dec2
          FROM core.school_fee_structures s
          JOIN core.school_fee_structure_details d ON d.fee_structure_id = s.fee_structure_id
         WHERE s.fee_structure_id = pg_temp.fsid(v_c3, 'ZZ H13');
        PERFORM pg_temp.chk('H13 annual total equals 12 x the stored monthly detail', v_dec = v_dec2,
                            format('annual %s vs 12 x detail %s', v_dec, v_dec2));
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H13 annual total equals 12 x the stored monthly detail', TRUE, 'refused: ' || SQLERRM);
    END;

    BEGIN
        v_msg := pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ H14', jsonb_build_array(pg_temp.d(h_tui, 999999999)));
        PERFORM pg_temp.chk('H14 an amount whose annual total overflows is refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('H14 an amount whose annual total overflows is refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- I. Downstream: ledger from a structure --------------------';

    -- s1 joins at session start, billed from class 1's saved structure.
    v_sid1 := pg_temp.admit('ZZ-FS-1', 'ZZ Sunrise Start', v_c1, v_s1, v_year, v_start, pg_temp.plan(v_c1, v_year));
    PERFORM pg_temp.chk('I1 a session-start admission from the structure succeeds', v_sid1 IS NOT NULL,
                        format('student %s', v_sid1));

    SELECT COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Tuition'),
           COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Annual Charges'),
           COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Activity'),
           COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Exam Fee')
      INTO v_n, v_m, v_dec, v_dec2
      FROM core.student_ledger WHERE student_id = v_sid1;
    PERFORM pg_temp.chk('I2 rows per cycle: 12 monthly, 4 quarterly, 2 half, 1 yearly',
                        v_n = 12 AND v_m = 4 AND v_dec = 2 AND v_dec2 = 1,
                        format('%s / %s / %s / %s', v_n, v_m, v_dec, v_dec2));

    SELECT COALESCE(SUM(amount_due), 0) INTO v_dec FROM core.student_ledger WHERE student_id = v_sid1;
    SELECT annual_total INTO v_dec2 FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk_eq('I3 the year billed equals the structure annual estimate', v_dec, v_dec2);

    SELECT installment_label INTO v_txt FROM core.student_ledger
     WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Annual Charges' ORDER BY due_date LIMIT 1;
    PERFORM pg_temp.chk('I4 first quarter is labelled as a three-month span',
                        v_txt = to_char(v_start, 'Mon YYYY') || ' - ' || to_char(v_start + INTERVAL '2 months', 'Mon YYYY'),
                        v_txt);

    SELECT string_agg(DISTINCT installment_label, ',') INTO v_txt FROM core.student_ledger
     WHERE student_id = v_sid1 AND frequency = 'One Time';
    PERFORM pg_temp.chk('I5 one-time heads are labelled "Admission"', v_txt = 'Admission', v_txt);

    SELECT amount_due INTO v_dec FROM core.student_ledger WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Caution Money';
    SELECT is_refundable INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_cau;
    PERFORM pg_temp.chk('I6 caution money billed once at 5,000; master says refundable',
                        v_dec = 5000 AND v_b, format('amount %s refundable %s', v_dec, v_b));

    -- s2 joins five months in (September of an April session).
    v_sid2 := pg_temp.admit('ZZ-FS-2', 'ZZ Sunrise Midyear', v_c1, v_s1, v_year,
                            (v_start + INTERVAL '5 months')::date, pg_temp.plan(v_c1, v_year));
    SELECT COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Tuition'),
           COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Annual Charges'),
           COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Activity')
      INTO v_n, v_m, v_dec FROM core.student_ledger WHERE student_id = v_sid2;
    PERFORM pg_temp.chk('I7 mid-year joiner: 7 months, 3 quarters, 2 halves',
                        v_n = 7 AND v_m = 3 AND v_dec = 2, format('%s / %s / %s', v_n, v_m, v_dec));
    SELECT MIN(due_date) INTO v_txt FROM core.student_ledger WHERE student_id = v_sid2 AND fee_head_name = 'ZZ Annual Charges';
    PERFORM pg_temp.chk('I8 ...whose first quarter snaps to the school quarter start',
                        v_txt = to_char(v_start + INTERVAL '3 months', 'YYYY-MM-DD'), v_txt);

    -- "Charge recurring fees from" = SessionStart bills the full session whatever
    -- the join date. (Fixture tweak on the year; rolled back with everything else.)
    UPDATE academic.academic_years SET charge_fees_from = 'SessionStart' WHERE academic_year_id = v_yearid;
    v_sid3 := pg_temp.admit('ZZ-FS-3', 'ZZ Sunrise Fullyear', v_c1, v_s1, v_year,
                            (v_start + INTERVAL '5 months')::date, pg_temp.plan(v_c1, v_year));
    UPDATE academic.academic_years SET charge_fees_from = 'AdmissionMonth' WHERE academic_year_id = v_yearid;
    SELECT COUNT(*) INTO v_n FROM core.student_ledger WHERE student_id = v_sid3 AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk_eq('I9 charge-from SessionStart bills all 12 months', v_n, 12);

    -- s1 pays April tuition, then the school revises tuition to 3,000.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Tuition' ORDER BY due_date LIMIT 1;
    v_rcpt := pg_temp.collect(v_sid1, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 2800, 'concession', 0)), v_year);
    v_msg := pg_temp.fs(c_tenant, c_school, v_c1, v_year, jsonb_build_array(
                 pg_temp.d(h_tui, 3000), pg_temp.d(h_ann, 1800), pg_temp.d(h_act, 3200),
                 pg_temp.d(h_exm, 2000), pg_temp.d(h_adm, 15000), pg_temp.d(h_cau, 5000)));

    SELECT COUNT(*) FILTER (WHERE amount_due <> 2800) INTO v_n FROM core.student_ledger
     WHERE student_id IN (v_sid1, v_sid2, v_sid3) AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk_eq('I10 revising the structure does not re-bill admitted students', v_n, 0);
    SELECT amount_paid INTO v_dec FROM core.student_ledger WHERE ledger_id = v_lid;
    PERFORM pg_temp.chk_eq('I11 ...and the April payment is intact', v_dec, 2800);
    SELECT amount INTO v_dec FROM core.student_fee_plan WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk_eq('I12 the frozen plan still says 2,800', v_dec, 2800);
    SELECT o_amt INTO v_dec FROM pg_temp.fs_det(c_tenant, c_school, v_c1, v_year) WHERE o_head = h_tui;
    PERFORM pg_temp.chk_eq('I13 the next admission is offered 3,000', v_dec, 3000);

    -- Changing the master's default amount is a default for new structures only.
    PERFORM pg_temp.fh(c_tenant, c_school, h_tui, 'ZZ Tuition', 'Monthly', 9999);
    SELECT amount INTO v_dec FROM core.school_fee_structure_details WHERE fee_structure_id = v_fs1 AND fee_head_id = h_tui;
    PERFORM pg_temp.chk_eq('I14 a new default amount leaves saved structures alone', v_dec, 3000);
    PERFORM pg_temp.fh(c_tenant, c_school, h_tui, 'ZZ Tuition', 'Monthly', 2500);

    -- Changing the master's billing CYCLE is different: the structure page now
    -- shows the head under the new cycle, but the saved detail keeps the old one,
    -- and admission bills from the detail (AdmissionController.GetFeeStructure ->
    -- d.Frequency). The class keeps being billed quarterly until someone re-saves
    -- every class structure.
    SELECT annual_total, half_yearly_total INTO v_dec2, v_dec FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    v_msg := pg_temp.fh(c_tenant, c_school, h_ann, 'ZZ Annual Charges', 'Half Yearly', 1800);
    SELECT frequency INTO v_txt FROM core.school_fee_structure_details WHERE fee_structure_id = v_fs1 AND fee_head_id = h_ann;
    PERFORM pg_temp.chk('I15 changing a head''s cycle reaches its saved structures', v_txt = 'Half Yearly',
                        format('structure says "%s"; %s', v_txt, v_msg));
    SELECT * INTO r FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    -- 1,800 moves from quarterly (x4) to half-yearly (x2): the annual drops 3,600
    -- and the half-yearly total (Activity is already there) grows by 1,800.
    PERFORM pg_temp.chk('I15b ...and its rollups are recomputed',
                        r.quarterly_total = 0 AND r.half_yearly_total = v_dec + 1800 AND r.annual_total = v_dec2 - 3600,
                        format('qtr %s half %s (was %s) annual %s (was %s)', r.quarterly_total, r.half_yearly_total, v_dec, r.annual_total, v_dec2));
    PERFORM pg_temp.fh(c_tenant, c_school, h_ann, 'ZZ Annual Charges', 'Quarterly', 1800);
    SELECT annual_total INTO v_dec FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk_eq('I15c ...and changing it back restores the annual', v_dec, v_dec2);

    -- Rename "ZZ Tuition" -> "ZZ Tuition Fee". First, give the OTHER school a
    -- receipt line that happens to carry the same head name.
    SELECT COUNT(*) INTO v_m FROM core.student_ledger
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Tuition';
    INSERT INTO core.fee_payments (tenant_id, school_id, student_id, receipt_no, amount, payment_mode, created_by)
    SELECT c_ot, c_os, MIN(student_id), 'ZZ-XSCHOOL-1', 100, 'Cash', c_user
      FROM core.students WHERE tenant_id = c_ot AND school_id = c_os
    RETURNING payment_id INTO v_pay;
    INSERT INTO core.fee_payment_details (payment_id, fee_head_name, amount) VALUES (v_pay, 'ZZ Tuition', 100);

    v_msg := pg_temp.fh(c_tenant, c_school, h_tui, 'ZZ Tuition Fee', 'Monthly', 2500);
    PERFORM pg_temp.chk('I16 rename succeeds and says how many rows moved', v_msg LIKE 'OK:%renamed from%', v_msg);

    SELECT COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Tuition'), COUNT(*) FILTER (WHERE fee_head_name = 'ZZ Tuition Fee')
      INTO v_n, v_dec FROM core.student_ledger WHERE tenant_id = c_tenant AND school_id = c_school;
    PERFORM pg_temp.chk('I17 every ledger row follows the rename', v_n = 0 AND v_dec = v_m,
                        format('old %s, new %s, expected %s', v_n, v_dec, v_m));
    SELECT COUNT(*) INTO v_n FROM core.student_fee_plan
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk_eq('I18 ...every frozen plan row', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_structure_details
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Tuition';
    PERFORM pg_temp.chk_eq('I19 ...every structure line', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d JOIN core.fee_payments p USING (payment_id)
     WHERE p.tenant_id = c_tenant AND p.school_id = c_school AND d.fee_head_name = 'ZZ Tuition Fee';
    PERFORM pg_temp.chk('I20 ...and this school''s receipt lines', v_n >= 1, format('%s line(s) renamed', v_n));

    -- THE ONE THAT MATTERS: the receipt-line UPDATE in the rename has no tenant or
    -- school filter, so it renames every school's receipts that share the name.
    SELECT fee_head_name INTO v_txt FROM core.fee_payment_details WHERE payment_id = v_pay;
    PERFORM pg_temp.chk('I21 rename does not touch another school''s receipts', v_txt = 'ZZ Tuition',
                        format('school %s receipt line now reads "%s"', c_os, v_txt));

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- J. Fee head delete: guards and cascade ------------------';

    -- Activity: three students owe it, nobody has paid it.
    SELECT COUNT(*) INTO v_m FROM core.student_ledger
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Activity';
    SELECT annual_total INTO v_dec2 FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    v_msg := pg_temp.fh_del(c_tenant, c_school, h_act);
    PERFORM pg_temp.chk('J1 an unpaid head deletes, and says what went with it',
                        v_msg LIKE 'OK:%ledger due%', v_msg);
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Activity';
    PERFORM pg_temp.chk('J2 its unpaid dues are gone', v_n = 0 AND v_m > 0, format('%s -> %s', v_m, v_n));
    SELECT COUNT(*) INTO v_n FROM core.student_fee_plan
     WHERE tenant_id = c_tenant AND school_id = c_school AND (fee_head_id = h_act OR fee_head_name = 'ZZ Activity');
    PERFORM pg_temp.chk_eq('J3 ...and its frozen plan rows', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_structure_details WHERE fee_head_id = h_act;
    PERFORM pg_temp.chk_eq('J4 ...and its structure lines', v_n, 0);
    SELECT half_yearly_total, annual_total INTO v_dec, v_dec2 FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk('J5 the class structure rollup is recomputed without it',
                        v_dec = 0 AND v_dec2 = 20000 + 36000 + 7200 + 2000,
                        format('half %s annual %s', v_dec, v_dec2));
    SELECT COALESCE(is_deleted, FALSE) AND NOT COALESCE(is_active, TRUE) INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_act;
    PERFORM pg_temp.chk('J6 the head itself is soft-deleted and inactive', v_b, format('%s', v_b));

    -- A structure whose only head is deleted is retired, not left at zero.
    PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ Solo', 'Monthly', 50);
    PERFORM pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ J7', jsonb_build_array(pg_temp.d(pg_temp.fid('ZZ Solo'), 50)));
    v_msg := pg_temp.fh_del(c_tenant, c_school, pg_temp.fid('ZZ Solo'));
    SELECT COALESCE(is_deleted, FALSE) INTO v_b FROM core.school_fee_structures WHERE fee_structure_id = pg_temp.fsid(v_c3, 'ZZ J7');
    PERFORM pg_temp.chk('J7 a structure left with no heads is retired', v_b AND v_msg LIKE '%retired%', v_msg);

    -- A head dropped from a structure earlier stays as a soft-deleted line. The
    -- delete's recompute must ignore it, or its amount comes back in the totals.
    DECLARE h_a int; h_b int; h_c int;
    BEGIN
        PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ JA', 'Monthly', 10);
        PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ JB', 'Monthly', 20);
        PERFORM pg_temp.fh(c_tenant, c_school, 0, 'ZZ JC', 'Monthly', 40);
        h_a := pg_temp.fid('ZZ JA'); h_b := pg_temp.fid('ZZ JB'); h_c := pg_temp.fid('ZZ JC');
        -- Structure 1: A, B, C, then C dropped. Structure 2: A, C, then C dropped.
        PERFORM pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ J7b', jsonb_build_array(pg_temp.d(h_a, 10), pg_temp.d(h_b, 20), pg_temp.d(h_c, 40)));
        PERFORM pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ J7b', jsonb_build_array(pg_temp.d(h_a, 10), pg_temp.d(h_b, 20)));
        PERFORM pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ J7c', jsonb_build_array(pg_temp.d(h_a, 10), pg_temp.d(h_c, 40)));
        PERFORM pg_temp.fs(c_tenant, c_school, v_c3, 'ZZ J7c', jsonb_build_array(pg_temp.d(h_a, 10)));
        PERFORM pg_temp.fh_del(c_tenant, c_school, h_a);

        SELECT monthly_total INTO v_dec FROM core.school_fee_structures WHERE fee_structure_id = pg_temp.fsid(v_c3, 'ZZ J7b');
        PERFORM pg_temp.chk_eq('J7b delete recomputes from live lines only (B = 20)', v_dec, 20);
        SELECT COALESCE(is_deleted, FALSE) INTO v_b FROM core.school_fee_structures WHERE fee_structure_id = pg_temp.fsid(v_c3, 'ZZ J7c');
        PERFORM pg_temp.chk('J7c a structure left with only dropped lines is retired', v_b, format('retired=%s', v_b));
    END;

    -- Tuition Fee: April was paid. Delete must refuse.
    SELECT COUNT(*) INTO v_m FROM core.student_ledger
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Tuition Fee';
    v_msg := pg_temp.fh_del(c_tenant, c_school, h_tui);
    PERFORM pg_temp.chk('J8 a head with a payment against it is refused', v_msg LIKE 'NO:%cannot be deleted%', left(v_msg, 70));
    PERFORM pg_temp.chk('J9 ...and the refusal names the way out (inactive)', v_msg LIKE '%inactive%', '');
    SELECT COUNT(*) INTO v_n FROM core.student_ledger
     WHERE tenant_id = c_tenant AND school_id = c_school AND fee_head_name = 'ZZ Tuition Fee';
    PERFORM pg_temp.chk_eq('J10 ...and not one ledger row was touched', v_n, v_m);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_structure_details
     WHERE fee_head_id = h_tui AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('J11 ...nor its structure lines', v_n >= 2, format('%s live line(s)', v_n));
    SELECT is_active AND NOT COALESCE(is_deleted, FALSE) INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    PERFORM pg_temp.chk('J12 ...and the head is still live', v_b, '');

    -- Annual Charges: a concession given, no cash. Still money against it.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Annual Charges' ORDER BY due_date LIMIT 1;
    PERFORM pg_temp.collect(v_sid1, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 0, 'concession', 100)),
                            v_year, 'Flat', 100, 'sibling discount');
    v_msg := pg_temp.fh_del(c_tenant, c_school, h_ann);
    PERFORM pg_temp.chk('J13 a head with only a concession against it is refused', v_msg LIKE 'NO:%', left(v_msg, 70));

    -- Exam Fee: a refund has been recorded against it. A refund can only follow
    -- money taken (chk_student_ledger_amounts refuses refunded > paid), so take
    -- 100 and refund it through the real procedures.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Exam Fee' ORDER BY due_date LIMIT 1;
    PERFORM pg_temp.collect(v_sid1, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 100, 'concession', 0)), v_year);
    DECLARE c_rf refcursor;
    BEGIN
        CALL core.sp_fee_refund_record(c_tenant, c_school, 39, v_sid1, v_lid, 100, 'Cash', 'exam not held', 'Principal', c_rf);
        CLOSE c_rf;
    END;
    v_msg := pg_temp.fh_del(c_tenant, c_school, h_exm);
    PERFORM pg_temp.chk('J14 a head with a refund against it is refused', v_msg LIKE 'NO:%', left(v_msg, 70));

    -- Admission Fee: paid, then the receipt cancelled. With the money reversed the
    -- delete goes through, and the cancelled receipt stays on record.
    SELECT ledger_id INTO v_lid FROM core.student_ledger
     WHERE student_id = v_sid1 AND fee_head_name = 'ZZ Admission Fee' LIMIT 1;
    v_rcpt := pg_temp.collect(v_sid1, jsonb_build_array(jsonb_build_object('ledgerId', v_lid, 'amount', 15000, 'concession', 0)), v_year);
    v_msg := pg_temp.fh_del(c_tenant, c_school, h_adm);
    PERFORM pg_temp.chk('J15 paid admission fee: delete refused', v_msg LIKE 'NO:%', left(v_msg, 60));
    c := NULL;
    CALL core.sp_fee_receipt_cancel(c_tenant, c_school, c_user, v_rcpt, 'wrong student', 'principal', c);
    CLOSE c;
    v_msg := pg_temp.fh_del(c_tenant, c_school, h_adm);
    PERFORM pg_temp.chk('J16 ...after the receipt is cancelled, delete goes through', v_msg LIKE 'OK:%', left(v_msg, 70));
    SELECT COUNT(*) INTO v_n FROM core.fee_payment_details d JOIN core.fee_payments p USING (payment_id)
     WHERE p.tenant_id = c_tenant AND p.school_id = c_school AND p.receipt_no = v_rcpt;
    PERFORM pg_temp.chk('J17 ...and the cancelled receipt''s lines are kept', v_n >= 1, format('%s line(s)', v_n));

    v_msg := pg_temp.fh_del(c_tenant, c_school, h_adm);
    PERFORM pg_temp.chk('J18 deleting the same head twice reports not found', v_msg LIKE 'NO:%not found%', v_msg);
    v_msg := pg_temp.fh_del(c_tenant, c_school, 999999);
    PERFORM pg_temp.chk('J19 deleting an unknown id reports not found', v_msg LIKE 'NO:%', v_msg);
    BEGIN
        v_msg := pg_temp.fh_del(c_tenant, c_school, 0);
        PERFORM pg_temp.chk('J20 delete with id 0 refused', FALSE, 'accepted: ' || v_msg);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('J20 delete with id 0 refused', TRUE, SQLERRM);
    END;

    v_msg := pg_temp.fh_toggle(c_tenant, c_school, h_adm);
    PERFORM pg_temp.chk('J21 a deleted head cannot be toggled', v_msg LIKE 'NO:%', v_msg);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fh_get(c_tenant, c_school) WHERE o_id = h_adm;
    PERFORM pg_temp.chk_eq('J22 a deleted head leaves the master list', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_tenant, c_school, 'ZZ Admission', NULL, 1, 10, NULL, 'asc');
    PERFORM pg_temp.chk_eq('J23 ...and the paged grid', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fh_byid(c_tenant, c_school, h_adm);
    PERFORM pg_temp.chk_eq('J24 ...and GetFeeHeadById', v_n, 0);
    v_msg := pg_temp.fh(c_tenant, c_school, h_adm, 'ZZ Admission Fee', 'One Time', 1);
    PERFORM pg_temp.chk('J25 editing a deleted head reports not found', v_msg LIKE 'NO:%', v_msg);

    v_msg := pg_temp.fh(c_tenant, c_school, 0, 'ZZ Admission Fee', 'One Time', 16000, 'Mandatory', 'Academic', 'Admission');
    PERFORM pg_temp.chk('J26 the name is free again: re-creating makes a NEW head',
                        pg_temp.fid('ZZ Admission Fee') IS NOT NULL AND pg_temp.fid('ZZ Admission Fee') <> h_adm,
                        format('old %s new %s', h_adm, pg_temp.fid('ZZ Admission Fee')));
    v_msg := pg_temp.fh(c_tenant, c_school, h_tra, 'ZZ Activity', 'Monthly', 1350, 'Mandatory', 'Transport');
    PERFORM pg_temp.chk('J27 renaming onto a deleted head''s name is allowed', v_msg LIKE 'OK:%', v_msg);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- K. Scope and cross-school isolation ----------------------';

    BEGIN
        PERFORM * FROM pg_temp.fh_get(1, 0);
        PERFORM pg_temp.chk('K1 GetFeeHead at platform scope refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K1 GetFeeHead at platform scope refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM * FROM pg_temp.fh_byid(c_tenant, 0, h_tui);
        PERFORM pg_temp.chk('K2 GetFeeHeadById with school 0 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K2 GetFeeHeadById with school 0 refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM * FROM pg_temp.fl(1, c_school, NULL, NULL, 1, 10, NULL, 'asc');
        PERFORM pg_temp.chk('K3 fee head list with tenant 1 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K3 fee head list with tenant 1 refused', TRUE, SQLERRM);
    END;
    BEGIN
        v_msg := pg_temp.fh_toggle(1, c_school, h_tui);
        PERFORM pg_temp.chk('K4 toggle with tenant 1 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K4 toggle with tenant 1 refused', TRUE, SQLERRM);
    END;
    BEGIN
        v_msg := pg_temp.fh_del(1, c_school, h_tui);
        PERFORM pg_temp.chk('K5 delete with tenant 1 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K5 delete with tenant 1 refused', TRUE, SQLERRM);
    END;
    BEGIN
        v_msg := pg_temp.fh(c_tenant, 0, 0, 'ZZ School Zero', 'Monthly', 1);
        PERFORM pg_temp.chk('K6 fee head save with school 0 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K6 fee head save with school 0 refused', TRUE, SQLERRM);
    END;
    BEGIN
        v_msg := pg_temp.fs(1, c_school, v_c3, 'ZZ K7', jsonb_build_array(pg_temp.d(h_tui, 1)));
        PERFORM pg_temp.chk('K7 structure save with tenant 1 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K7 structure save with tenant 1 refused', TRUE, SQLERRM);
    END;
    BEGIN
        v_msg := pg_temp.fs(c_tenant, 0, v_c3, 'ZZ K8', jsonb_build_array(pg_temp.d(h_tui, 1)));
        PERFORM pg_temp.chk('K8 structure save with school 0 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K8 structure save with school 0 refused', TRUE, SQLERRM);
    END;
    BEGIN
        PERFORM * FROM pg_temp.fs_list(1, 0);
        PERFORM pg_temp.chk('K9 structure list at platform scope refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K9 structure list at platform scope refused', TRUE, SQLERRM);
    END;
    BEGIN
        v_msg := pg_temp.fs_del(1, c_school, v_fs1);
        PERFORM pg_temp.chk('K10 structure delete with tenant 1 refused', FALSE, 'accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('K10 structure delete with tenant 1 refused', TRUE, SQLERRM);
    END;

    -- The other school, using OUR ids.
    SELECT COUNT(*) INTO v_n FROM pg_temp.fh_byid(c_ot, c_os, h_tui);
    PERFORM pg_temp.chk_eq('K11 another school cannot read our head by id', v_n, 0);

    v_msg := pg_temp.fh(c_ot, c_os, h_tui, 'Hijacked', 'Monthly', 1);
    SELECT fee_head_name INTO v_txt FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    PERFORM pg_temp.chk('K12 another school cannot edit our head', v_msg LIKE 'NO:%' AND v_txt = 'ZZ Tuition Fee',
                        format('%s / name %s', v_msg, v_txt));

    SELECT is_active INTO v_b FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    v_msg := pg_temp.fh_toggle(c_ot, c_os, h_tui);
    PERFORM pg_temp.chk('K13 another school cannot toggle our head',
                        v_msg LIKE 'NO:%' AND (SELECT is_active FROM core.school_fee_heads WHERE fee_head_id = h_tui) = v_b,
                        v_msg);

    v_msg := pg_temp.fh_del(c_ot, c_os, h_free);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads WHERE fee_head_id = h_free AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk('K14 another school cannot delete our head', v_msg LIKE 'NO:%' AND v_n = 1, v_msg);

    SELECT COUNT(*) INTO v_n FROM pg_temp.fl(c_ot, c_os, 'ZZ ', NULL, 1, 200, NULL, 'asc');
    PERFORM pg_temp.chk_eq('K15 our heads do not appear in another school''s grid', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fh_get(c_ot, c_os) WHERE o_name LIKE 'ZZ %';
    PERFORM pg_temp.chk_eq('K16 ...nor in its master list', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM pg_temp.fs_det(c_ot, c_os, v_c1, v_year);
    PERFORM pg_temp.chk_eq('K17 another school cannot read our class structure', v_n, 0);
    SELECT COUNT(*) INTO v_n FROM pg_temp.fs_list(c_ot, c_os) WHERE o_id IN (v_fs1, v_fs2, v_fsn);
    PERFORM pg_temp.chk_eq('K18 ...nor see it listed', v_n, 0);

    v_msg := pg_temp.fs_del(c_ot, c_os, v_fs1);
    SELECT COALESCE(is_deleted, FALSE) INTO v_b FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk('K19 another school cannot delete our structure', v_msg LIKE 'NO:%' AND NOT v_b, v_msg);

    -- The same class + session name in the other school is its own structure.
    SELECT annual_total INTO v_dec2 FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    v_msg := pg_temp.fs(c_ot, c_os, v_c1, v_year, jsonb_build_array(
                 jsonb_build_object('feeHeadId', (SELECT fee_head_id FROM core.school_fee_heads
                                                   WHERE tenant_id = c_ot AND school_id = c_os
                                                     AND COALESCE(is_deleted, FALSE) = FALSE LIMIT 1),
                                    'feeHeadName', 'Other', 'frequency', 'One Time', 'amount', 1)));
    SELECT annual_total INTO v_dec FROM core.school_fee_structures WHERE fee_structure_id = v_fs1;
    PERFORM pg_temp.chk('K20 the other school saving the same class+session leaves ours alone',
                        v_msg LIKE 'OK:%' AND v_dec = v_dec2 AND pg_temp.fsid(v_c1, v_year) = v_fs1,
                        format('our annual %s before, %s after', v_dec2, v_dec));

    v_msg := pg_temp.fh(c_ot, c_os, 0, 'ZZ Tuition Fee', 'Monthly', 1);
    SELECT COUNT(*) INTO v_n FROM core.school_fee_heads
     WHERE lower(fee_head_name) = 'zz tuition fee' AND COALESCE(is_deleted, FALSE) = FALSE;
    SELECT default_amount INTO v_dec FROM core.school_fee_heads WHERE fee_head_id = h_tui;
    PERFORM pg_temp.chk('K21 the same head name in two schools is two heads',
                        v_n = 2 AND v_dec = 2500, format('%s heads, ours still %s', v_n, v_dec));

    SELECT COUNT(*) INTO v_n FROM config.permissions
     WHERE permission_key IN ('fees.view', 'fees.manage') AND COALESCE(is_active, TRUE);
    PERFORM pg_temp.chk_eq('K22 fees.view / fees.manage exist for the page guards', v_n, 2);
END
$suite$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 60), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
