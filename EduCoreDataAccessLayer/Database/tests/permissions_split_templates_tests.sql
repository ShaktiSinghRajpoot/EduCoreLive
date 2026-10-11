-- ============================================================================
-- Permission split test suite: exams.marks and fees.reopen (2026-10-11).
--
-- permissions_exams_reopen.sql added two keys:
--   exams.marks  -- enter / finalise marks; copied to every role with exams.manage,
--                   and built-in TEACHER roles lost their default exams.manage;
--   fees.reopen  -- re-open a closed fee day; deliberately granted to nobody.
-- builtin_role_defaults.sql now gives TEACHER exams.marks instead of exams.manage.
-- (Role templates are C#-only -- educore/Helpers/RoleTemplates.cs -- and are
-- applied through config.sp_role_permissions_save, which roles_tests.sql covers.)
--
-- Needs both scripts applied first. Runs inside ONE transaction and ROLLS BACK.
-- It re-runs both scripts (with \ir) to prove a re-run changes nothing.
--
--     psql ... -f permissions_split_templates_tests.sql
--
-- COVERS
--   A. The keys
--   B. The migration's grants
--   C. Re-running the scripts
--   D. A school's own choice survives a re-run
--   E. Defaults for a new school
--   F. Scope
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _snap(name text PRIMARY KEY, n bigint) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.chk(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO _t(name, ok, detail) VALUES (p_name, p_ok, p_detail);
    RAISE NOTICE '  [%] %  %', CASE WHEN p_ok THEN 'PASS' ELSE 'FAIL' END, rpad(p_name, 54), p_detail;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.chk_eq(p_name text, p_got numeric, p_want numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.chk(p_name, p_got IS NOT DISTINCT FROM p_want,
                        format('got %s, expected %s', COALESCE(p_got::text,'NULL'), p_want));
END $$;

-- Live grant keys of one role, sorted and comma-joined.
CREATE OR REPLACE FUNCTION pg_temp.role_keys(p_tenant integer, p_role integer)
RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg(p.permission_key, ',' ORDER BY p.permission_key), '')
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.tenant_id = p_tenant AND rp.role_id = p_role
      AND rp.is_deleted = FALSE AND rp.is_allowed = TRUE;
$$;


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    v_teacher integer;
    v_n       integer;
    v_txt     text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '===== PERMISSION SPLIT (exams.marks / fees.reopen) TESTS =====';

    SELECT role_id INTO v_teacher FROM config.roles
     WHERE tenant_id = c_tenant AND role_code = 'TEACHER' AND NOT is_deleted;
    IF v_teacher IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: tenant % has no TEACHER role.', c_tenant;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. The keys ------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM config.permissions
     WHERE permission_key = 'exams.marks' AND is_active AND module_group = 'Academic';
    PERFORM pg_temp.chk_eq('A1 exams.marks exists (Academic, active)', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM config.permissions
     WHERE permission_key = 'fees.reopen' AND is_active AND module_group = 'Finance';
    PERFORM pg_temp.chk_eq('A2 fees.reopen exists (Finance, active)', v_n, 1);

    -- The Roles page shows the text after the dash as the extra tick's label.
    SELECT display_name INTO v_txt FROM config.permissions WHERE permission_key = 'exams.marks';
    PERFORM pg_temp.chk('A3 exams.marks labelled under Examinations',
                        v_txt LIKE 'Examinations — %', v_txt);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. The migration''s grants ---------------------------';

    -- Nobody lost mark entry: every live exams.manage grant has a live exams.marks.
    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp
    JOIN config.permissions mp ON mp.permission_id = rp.permission_id AND mp.permission_key = 'exams.manage'
    WHERE rp.is_deleted = FALSE
      AND NOT EXISTS (SELECT 1 FROM config.role_permissions x
                      JOIN config.permissions np ON np.permission_id = x.permission_id AND np.permission_key = 'exams.marks'
                      WHERE x.tenant_id IS NOT DISTINCT FROM rp.tenant_id
                        AND x.school_id IS NOT DISTINCT FROM rp.school_id
                        AND x.role_id = rp.role_id AND x.is_deleted = FALSE);
    PERFORM pg_temp.chk_eq('B1 every exams.manage grant also has exams.marks', v_n, 0);

    -- Built-in teachers keep no untouched default exams.manage.
    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp
    JOIN config.roles ro ON ro.role_id = rp.role_id AND ro.role_code = 'TEACHER'
    JOIN config.permissions p ON p.permission_id = rp.permission_id AND p.permission_key = 'exams.manage'
    WHERE rp.is_deleted = FALSE AND rp.created_by = 0 AND COALESCE(rp.updated_by, 0) = 0;
    PERFORM pg_temp.chk_eq('B2 no TEACHER keeps the default exams.manage', v_n, 0);

    -- ...and every teacher that got the defaults can still enter marks.
    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp
    JOIN config.roles ro ON ro.role_id = rp.role_id AND ro.role_code = 'TEACHER'
    JOIN config.permissions p ON p.permission_id = rp.permission_id AND p.permission_key = 'exams.view'
    WHERE rp.is_deleted = FALSE AND rp.created_by = 0
      AND NOT EXISTS (SELECT 1 FROM config.role_permissions x
                      JOIN config.permissions m ON m.permission_id = x.permission_id AND m.permission_key = 'exams.marks'
                      WHERE x.role_id = rp.role_id AND x.tenant_id = rp.tenant_id AND x.is_deleted = FALSE);
    PERFORM pg_temp.chk_eq('B3 every default TEACHER has exams.marks', v_n, 0);

    v_txt := pg_temp.role_keys(c_tenant, v_teacher);
    PERFORM pg_temp.chk('B4 fixture teacher: exams.marks, not exams.manage',
                        v_txt LIKE '%exams.marks%' AND v_txt NOT LIKE '%exams.manage%', v_txt);

    -- What the runtime resolver hands the permission service for that teacher.
    DECLARE c refcursor := 'b5'; k text; v_marks boolean := FALSE; v_manage boolean := FALSE;
    BEGIN
        CALL config.sp_role_permissions_resolve(c_tenant, c_school, v_teacher, c);
        LOOP
            FETCH c INTO k;
            EXIT WHEN NOT FOUND;
            IF k = 'exams.marks'  THEN v_marks  := TRUE; END IF;
            IF k = 'exams.manage' THEN v_manage := TRUE; END IF;
        END LOOP;
        CLOSE c;
        PERFORM pg_temp.chk('B5 resolver: teacher has exams.marks only',
                            v_marks AND NOT v_manage, format('marks=%s manage=%s', v_marks, v_manage));
    END;

    -- fees.reopen is never handed out automatically.
    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE p.permission_key = 'fees.reopen' AND rp.created_by = 0;
    PERFORM pg_temp.chk_eq('B6 fees.reopen not auto-granted to any role', v_n, 0);

    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp
    JOIN config.roles ro ON ro.role_id = rp.role_id AND ro.role_code IN ('TEACHER','ACCOUNTANT','RECEPTIONIST')
    JOIN config.permissions p ON p.permission_id = rp.permission_id AND p.permission_key = 'fees.reopen'
    WHERE rp.is_deleted = FALSE;
    PERFORM pg_temp.chk_eq('B7 no built-in role holds fees.reopen', v_n, 0);

    -- Snapshot for the re-run checks.
    INSERT INTO _snap VALUES
        ('perms',  (SELECT COUNT(*) FROM config.permissions)),
        ('grants', (SELECT COUNT(*) FROM config.role_permissions)),
        ('live',   (SELECT COUNT(*) FROM config.role_permissions WHERE is_deleted = FALSE)),
        ('reopen', (SELECT COUNT(*) FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
                     WHERE p.permission_key = 'fees.reopen'));
END
$suite$;


-- ── C. re-run both scripts inside this transaction ──────────────────────────
\ir ../permissions_exams_reopen.sql
\ir ../builtin_role_defaults.sql

DO $rerun$
DECLARE v_n bigint;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Re-running the scripts ---------------------------';

    SELECT COUNT(*) INTO v_n FROM config.permissions;
    PERFORM pg_temp.chk_eq('C1 re-run adds no permission keys', v_n, (SELECT n FROM _snap WHERE name = 'perms'));

    SELECT COUNT(*) INTO v_n FROM config.role_permissions;
    PERFORM pg_temp.chk_eq('C2 re-run adds no grant rows', v_n, (SELECT n FROM _snap WHERE name = 'grants'));

    SELECT COUNT(*) INTO v_n FROM config.role_permissions WHERE is_deleted = FALSE;
    PERFORM pg_temp.chk_eq('C3 re-run removes no live grants', v_n, (SELECT n FROM _snap WHERE name = 'live'));

    SELECT COUNT(*) INTO v_n FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
     WHERE p.permission_key = 'fees.reopen';
    PERFORM pg_temp.chk_eq('C4 re-run grants no fees.reopen', v_n, (SELECT n FROM _snap WHERE name = 'reopen'));
END
$rerun$;


-- ── D. a school re-ticks exams.manage for its teachers on the Roles page ────
DO $retick$
DECLARE
    v_teacher integer;
    v_ids     integer[];
    c         refcursor := 'd1';
BEGIN
    SELECT role_id INTO v_teacher FROM config.roles WHERE tenant_id = 24 AND role_code = 'TEACHER' AND NOT is_deleted;
    SELECT array_agg(DISTINCT rp.permission_id) || (SELECT permission_id FROM config.permissions WHERE permission_key = 'exams.manage')
      INTO v_ids
    FROM config.role_permissions rp
    WHERE rp.tenant_id = 24 AND rp.role_id = v_teacher AND rp.is_deleted = FALSE;
    CALL config.sp_role_permissions_save(24, 34, 39, v_teacher, v_ids, c);
END
$retick$;

\ir ../permissions_exams_reopen.sql

DO $kept$
DECLARE
    v_teacher integer;
    v_txt     text;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '-- D. A school''s own choice survives a re-run -----------';

    SELECT role_id INTO v_teacher FROM config.roles WHERE tenant_id = 24 AND role_code = 'TEACHER' AND NOT is_deleted;
    v_txt := pg_temp.role_keys(24, v_teacher);
    PERFORM pg_temp.chk('D1 re-ticked exams.manage kept by the re-run',
                        v_txt LIKE '%exams.manage%' AND v_txt LIKE '%exams.marks%', v_txt);
END
$kept$;


DO $fresh$
DECLARE
    c_new_school CONSTANT integer := 999999;   -- a school id with no grants yet
    v_added   integer;
    v_teacher integer;
    v_acc     integer;
    v_txt     text;
    v_n       integer;
    v_t23     bigint;
    c         refcursor;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Defaults for a new school -------------------------';

    SELECT COUNT(*) INTO v_t23 FROM config.role_permissions WHERE tenant_id = 23;

    v_added := config.fn_apply_builtin_role_defaults(24, c_new_school, 0);
    PERFORM pg_temp.chk('E1 defaults applied to a new school', v_added > 0, format('%s grant(s)', v_added));

    SELECT role_id INTO v_teacher FROM config.roles WHERE tenant_id = 24 AND role_code = 'TEACHER'    AND NOT is_deleted;
    SELECT role_id INTO v_acc     FROM config.roles WHERE tenant_id = 24 AND role_code = 'ACCOUNTANT' AND NOT is_deleted;

    SELECT string_agg(p.permission_key, ',' ORDER BY p.permission_key) INTO v_txt
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.tenant_id = 24 AND rp.school_id = c_new_school AND rp.role_id = v_teacher AND rp.is_deleted = FALSE;
    PERFORM pg_temp.chk('E2 new school TEACHER = the new teacher set',
        v_txt = 'academics.view,attendance.manage,attendance.view,exams.marks,exams.view,students.view', v_txt);

    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.tenant_id = 24 AND rp.school_id = c_new_school AND p.permission_key IN ('exams.manage', 'fees.reopen');
    PERFORM pg_temp.chk_eq('E3 new school: no exams.manage / fees.reopen granted', v_n, 0);

    SELECT COUNT(*) INTO v_n
    FROM config.role_permissions rp JOIN config.permissions p USING (permission_id)
    WHERE rp.tenant_id = 24 AND rp.school_id = c_new_school AND rp.role_id = v_acc
      AND p.permission_key = 'fees.manage';
    PERFORM pg_temp.chk_eq('E4 new school ACCOUNTANT still gets fees.manage', v_n, 1);

    v_added := config.fn_apply_builtin_role_defaults(24, c_new_school, 0);
    PERFORM pg_temp.chk_eq('E5 applying the defaults twice adds nothing', v_added, 0);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- F. Scope ---------------------------------------------';

    SELECT COUNT(*) INTO v_n FROM config.role_permissions WHERE tenant_id = 23;
    PERFORM pg_temp.chk_eq('F1 tenant 24 defaults wrote nothing for tenant 23', v_n, v_t23);

    -- School 23/33 cannot change the ticks of school 24's teacher role.
    SELECT permission_id INTO v_n FROM config.permissions WHERE permission_key = 'exams.marks';
    BEGIN
        c := 'f2';
        CALL config.sp_role_permissions_save(23, 33, 39, v_teacher, ARRAY[v_n], c);
        PERFORM pg_temp.chk('F2 another tenant cannot edit our role', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('F2 another tenant cannot edit our role', TRUE, SQLERRM);
    END;

    PERFORM pg_temp.chk_eq('F3 defaults for tenant 1 (platform) refused',
                           config.fn_apply_builtin_role_defaults(1, 1, 0), 0);
END
$fresh$;


DO $sum$
DECLARE p integer; f integer; r record;
BEGIN
    SELECT COUNT(*) FILTER (WHERE ok), COUNT(*) FILTER (WHERE NOT ok) INTO p, f FROM _t;
    RAISE NOTICE '';
    RAISE NOTICE '========== RESULT: % passed, % failed ==========', p, f;
    IF f > 0 THEN
        RAISE NOTICE 'failures:';
        FOR r IN SELECT name, detail FROM _t WHERE NOT ok ORDER BY id LOOP
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
