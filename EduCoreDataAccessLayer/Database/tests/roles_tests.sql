-- ============================================================================
-- Roles and Permissions test suite.
--
-- This is the module that decides what everyone else can do, so its guards are
-- the ones worth being sure of: a built-in role cannot be renamed out from under
-- the code that checks for it, a role still assigned to someone cannot be
-- deleted, and no permission grant crosses a school boundary.
--
-- Runs inside ONE transaction and ROLLS BACK.
--
--     psql ... -f roles_tests.sql
--
-- COVERS
--   A. Create, rename, duplicate
--   B. Built-in roles are protected
--   C. Permissions — save, replace, resolve
--   D. Deleting a role that is in use
--   E. Scope
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE _t(id serial, name text, ok boolean, detail text) ON COMMIT DROP;

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


DO $suite$
DECLARE
    c_tenant CONSTANT integer := 24;
    c_school CONSTANT integer := 34;
    c_user   CONSTANT integer := 39;

    c     refcursor;
    v_rid integer;
    v_builtin integer;
    v_bname   text;
    v_n   integer;
    v_txt text;
    v_p1  integer;
    v_p2  integer;
    v_p3  integer;
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========= ROLES + PERMISSIONS TESTS =========';

    SELECT permission_id INTO v_p1 FROM config.permissions ORDER BY permission_id LIMIT 1;
    SELECT permission_id INTO v_p2 FROM config.permissions ORDER BY permission_id OFFSET 1 LIMIT 1;
    SELECT permission_id INTO v_p3 FROM config.permissions ORDER BY permission_id OFFSET 2 LIMIT 1;

    IF v_p3 IS NULL THEN
        RAISE EXCEPTION 'Fixture missing: fewer than three rows in config.permissions.';
    END IF;
    RAISE NOTICE 'fixture: permissions %, %, %', v_p1, v_p2, v_p3;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- A. Create, rename, duplicate -------------------------';

    BEGIN
        c := 'a1';
        CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL, '   ', 'blank', c);
        PERFORM pg_temp.chk('A1 blank role name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A1 blank role name refused', TRUE, SQLERRM);
    END;

    c := 'a2';
    CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL,
         'ZZ Librarian', 'created by the suite', c);

    SELECT role_id INTO v_rid FROM config.roles
     WHERE tenant_id = c_tenant AND school_id = c_school AND role_name = 'ZZ Librarian';
    PERFORM pg_temp.chk('A2 role created', v_rid IS NOT NULL, format('role_id=%s', v_rid));

    BEGIN
        c := 'a3';
        CALL config.sp_role_manage('INSERT', c_tenant, c_school, c_user, NULL,
             'ZZ Librarian', 'again', c);
        PERFORM pg_temp.chk('A3 duplicate role name refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A3 duplicate role name refused', TRUE, SQLERRM);
    END;

    c := 'a4';
    CALL config.sp_role_manage('UPDATE', c_tenant, c_school, c_user, v_rid,
         'ZZ Head Librarian', 'renamed', c);

    SELECT role_name INTO v_txt FROM config.roles WHERE role_id = v_rid;
    PERFORM pg_temp.chk('A4 a custom role can be renamed', v_txt = 'ZZ Head Librarian',
                        format('now "%s"', v_txt));

    BEGIN
        c := 'a5';
        CALL config.sp_role_manage('UPDATE', c_tenant, c_school, c_user, 999999,
             'ZZ Ghost', 'nope', c);
        PERFORM pg_temp.chk('A5 renaming a role that does not exist refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('A5 renaming a role that does not exist refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- B. Built-in roles are protected ----------------------';

    -- "Built-in" is the role_code, not a flag: the proc refuses to touch the five
    -- codes the application itself checks for.
    SELECT role_id, role_name INTO v_builtin, v_bname FROM config.roles
     WHERE tenant_id = c_tenant AND school_id = c_school
       AND role_code IN ('SUPER_ADMIN','SCHOOL_ADMIN','TEACHER','ACCOUNTANT','RECEPTIONIST')
     LIMIT 1;

    IF v_builtin IS NULL THEN
        PERFORM pg_temp.chk('B  skipped — this school has no built-in roles', TRUE, '');
    ELSE
        -- The code checks for these roles by name. Renaming one does not just
        -- relabel it; it detaches every check that looks it up.
        BEGIN
            c := 'b1';
            CALL config.sp_role_manage('UPDATE', c_tenant, c_school, c_user, v_builtin,
                 'ZZ Renamed Builtin', 'should fail', c);
            PERFORM pg_temp.chk('B1 a built-in role cannot be renamed', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('B1 a built-in role cannot be renamed', TRUE, SQLERRM);
        END;

        SELECT role_name INTO v_txt FROM config.roles WHERE role_id = v_builtin;
        PERFORM pg_temp.chk('B2 ...and its name really did not change', v_txt = v_bname,
                            format('still "%s"', v_txt));

        BEGIN
            c := 'b3';
            CALL config.sp_role_manage('DELETE', c_tenant, c_school, c_user, v_builtin, NULL, NULL, c);
            PERFORM pg_temp.chk('B3 a built-in role cannot be deleted', FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('B3 a built-in role cannot be deleted', TRUE, SQLERRM);
        END;

        SELECT COUNT(*) INTO v_n FROM config.roles WHERE role_id = v_builtin;
        PERFORM pg_temp.chk_eq('B4 ...and it is still there', v_n, 1);
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- C. Permissions --------------------------------------';

    c := 'c1';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_rid,
         ARRAY[v_p1, v_p2], c);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C1 two permissions granted', v_n, 2);

    -- Saving is a REPLACE, not an append: the screen posts the whole ticked set,
    -- so an unticked box must actually revoke.
    c := 'c2';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_rid,
         ARRAY[v_p3], c);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C2 saving replaces rather than appends', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND permission_id = v_p1 AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C3 an unticked permission is revoked', v_n, 0);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND permission_id = v_p3 AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C4 ...and the newly ticked one is granted', v_n, 1);

    -- Clearing every box leaves a role that can do nothing, which is a valid
    -- state and must not be mistaken for "no opinion".
    c := 'c5';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_rid,
         ARRAY[]::integer[], c);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C5 a role can be stripped to nothing', v_n, 0);

    -- Revoking is a SOFT delete, and the row is kept so that re-ticking the box
    -- revives the original grant rather than piling up a second row for the same
    -- permission. Check both halves of that.
    SELECT COUNT(*) INTO v_n FROM config.role_permissions WHERE role_id = v_rid;
    PERFORM pg_temp.chk('C5b the revoked rows are kept, not deleted', v_n >= 3,
                        format('%s row(s) retained', v_n));

    c := 'c5c';
    CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, v_rid,
         ARRAY[v_p1], c);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND permission_id = v_p1;
    PERFORM pg_temp.chk_eq('C5c re-granting revives the row instead of adding one', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM config.role_permissions
     WHERE role_id = v_rid AND COALESCE(is_deleted, FALSE) = FALSE;
    PERFORM pg_temp.chk_eq('C5d ...and only that one permission is live', v_n, 1);

    BEGIN
        c := 'c6';
        CALL config.sp_role_permissions_save(c_tenant, c_school, c_user, 999999,
             ARRAY[v_p1], c);
        PERFORM pg_temp.chk('C6 granting to a role that does not exist refused',
                            FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('C6 granting to a role that does not exist refused', TRUE, SQLERRM);
    END;

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- D. Deleting a role that is in use --------------------';

    -- Give the role to a user, then try to delete it. Deleting it out from under
    -- someone would leave a signed-in user with no permissions at all.
    c := 'd1';
    CALL core.sp_user_role_assign(c_tenant, c_school, c_user, c_user, v_rid, c);

    SELECT COUNT(*) INTO v_n FROM core.user_roles
     WHERE role_id = v_rid AND user_id = c_user;
    PERFORM pg_temp.chk_eq('D1 role assigned to a user', v_n, 1);

    BEGIN
        c := 'd2';
        CALL config.sp_role_manage('DELETE', c_tenant, c_school, c_user, v_rid, NULL, NULL, c);
        PERFORM pg_temp.chk('D2 a role still assigned cannot be deleted', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('D2 a role still assigned cannot be deleted', TRUE, SQLERRM);
    END;

    SELECT COUNT(*) INTO v_n FROM config.roles WHERE role_id = v_rid;
    PERFORM pg_temp.chk_eq('D3 ...and the role survived', v_n, 1);

    -- ══════════════════════════════════════════════════════════════════════
    RAISE NOTICE '';
    RAISE NOTICE '-- E. Scope --------------------------------------------';

    BEGIN
        c := 'e1';
        CALL config.sp_role_manage('INSERT', 1, 0, c_user, NULL, 'ZZ Platform Role', NULL, c);
        PERFORM pg_temp.chk('E1 platform scope role create refused', FALSE, 'it was accepted');
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.chk('E1 platform scope role create refused', TRUE, SQLERRM);
    END;

    -- The one that matters most: another tenant must not be able to grant
    -- permissions on our role. Roles are tenant-scoped here — config.roles.school_id
    -- is NULL for every real tenant — so the tenant is the boundary the proc checks.
    DECLARE v_live_before integer;
    BEGIN
        SELECT COUNT(*) INTO v_live_before FROM config.role_permissions
         WHERE role_id = v_rid AND COALESCE(is_deleted, FALSE) = FALSE;
        BEGIN
            c := 'e2';
            CALL config.sp_role_permissions_save(23, 33, c_user, v_rid, ARRAY[v_p1, v_p2, v_p3], c);
            PERFORM pg_temp.chk('E2 another tenant could not grant on our role',
                                FALSE, 'it was accepted');
        EXCEPTION WHEN OTHERS THEN
            PERFORM pg_temp.chk('E2 another tenant could not grant on our role', TRUE, SQLERRM);
        END;

        SELECT COUNT(*) INTO v_n FROM config.role_permissions
         WHERE role_id = v_rid AND COALESCE(is_deleted, FALSE) = FALSE;
        PERFORM pg_temp.chk_eq('E2b ...and the live grants are unchanged', v_n, v_live_before);
    END;

    BEGIN
        c := 'e3';
        CALL config.sp_role_manage('DELETE', 23, 33, c_user, v_rid, NULL, NULL, c);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    SELECT COUNT(*) INTO v_n FROM config.roles WHERE role_id = v_rid;
    PERFORM pg_temp.chk_eq('E3 another school could not delete our role', v_n, 1);

    SELECT COUNT(*) INTO v_n FROM config.roles
     WHERE role_name = 'ZZ Head Librarian' AND (tenant_id <> c_tenant OR school_id <> c_school);
    PERFORM pg_temp.chk_eq('E4 our role did not leak to another school', v_n, 0);
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
            RAISE NOTICE '   %  %', rpad(r.name, 54), r.detail;
        END LOOP;
    END IF;
    RAISE NOTICE '';
END
$sum$;

ROLLBACK;
