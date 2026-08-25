-- ============================================================================
-- Public ids for students, staff and transfer certificates — a stable,
-- non-guessable id for URLs.
--
-- WHY THIS EXISTS. Record ids travel in URLs as plain integers
-- (/ERP/Staff/StaffProfile/12). The integer is not a security hole — every read
-- is already scoped by tenant_id + school_id in the controller, the service and
-- the proc, so a guessed id from another school returns nothing (audited: all 49
-- id-taking actions, zero missing filters). What the integer DOES leak is
-- volume: /Student/4700 returning a page tells you roughly how many students the
-- school has, and that ids are sequential.
--
-- A uuid fixes that and, unlike an encrypted token, is STABLE — it survives key
-- rotation, redeploys and a lost Data Protection key ring, so bookmarked and
-- emailed links keep working. (An IDataProtector token was tried first and
-- reverted; see docs/SCALING-AND-FIXES.md for the measurements.)
--
-- The integer PRIMARY KEY stays exactly as it is. public_id is an extra column
-- for the outside world only. Every foreign key, join and index is untouched —
-- making uuid the PK would bloat every index for no benefit.
--
-- ---------------------------------------------------------------------------
-- BEFORE YOU RUN THIS
--
--   * gen_random_uuid() is built into PostgreSQL 13+. Local is 16, Railway is
--     18 — no pgcrypto extension needed on either.
--
--   * ADD COLUMN with a VOLATILE default (gen_random_uuid()) CANNOT use the
--     catalog fast path: PostgreSQL rewrites the table so every row gets its own
--     uuid, holding an ACCESS EXCLUSIVE lock for the duration. That is what we
--     want, but it means the table is locked while it runs. At this app's size
--     (tens of thousands of rows) it is seconds — still, run it in a quiet
--     window. For a very large table use the slow path instead: add the column
--     nullable, backfill in batches, then SET NOT NULL.
--
--   * Local dev and the Railway app SHARE ONE DATABASE. This script only ADDS
--     things — no proc signature changes, nothing dropped — so a build that
--     knows nothing about public_id keeps working unchanged. That is deliberate:
--     the 42883 incident (see the change log) came from changing a signature
--     while an older build was still live.
--
-- Target DB: PostgreSQL 13+. Safe to re-run.
-- ============================================================================

BEGIN;

-- ── 1. the columns ──────────────────────────────────────────────────────────
ALTER TABLE core.students
    ADD COLUMN IF NOT EXISTS public_id uuid NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE core.staff
    ADD COLUMN IF NOT EXISTS public_id uuid NOT NULL DEFAULT gen_random_uuid();

-- The issued certificate. Its URL opens a printable document, so it is exactly the
-- kind of link that gets shared outside the app.
ALTER TABLE core.tc_register
    ADD COLUMN IF NOT EXISTS public_id uuid NOT NULL DEFAULT gen_random_uuid();

-- ── 2. lookup indexes ───────────────────────────────────────────────────────
-- UNIQUE, not just an index: a duplicate public_id would let one school's URL
-- resolve to another school's row. uuid collisions are vanishingly unlikely,
-- but "unlikely" is not a constraint.
CREATE UNIQUE INDEX IF NOT EXISTS ux_students_public_id ON core.students(public_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_staff_public_id    ON core.staff(public_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_tc_register_public_id ON core.tc_register(public_id);

-- ── 3. uuid -> internal id, WITH the tenant check ───────────────────────────
-- The resolution itself is scoped. A uuid belonging to another school resolves
-- to NULL, exactly like a uuid that does not exist — the caller cannot tell the
-- two apart, so this cannot be used to probe which ids are real.
--
-- Returning NULL (not raising) is deliberate: the calling service already treats
-- null as "not found" and redirects. Same path as a deleted record.
CREATE OR REPLACE FUNCTION core.fn_public_id_to_id(
    p_entity    text,
    p_public_id uuid,
    p_tenant_id integer,
    p_school_id integer
) RETURNS integer
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id integer;
BEGIN
    -- Same guard the services use: tenant 1 is the platform, not a school.
    IF p_public_id IS NULL OR p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RETURN NULL;
    END IF;

    CASE lower(p_entity)
        WHEN 'student' THEN
            SELECT s.student_id INTO v_id
            FROM   core.students s
            WHERE  s.public_id = p_public_id
              AND  s.tenant_id = p_tenant_id
              AND  s.school_id = p_school_id;

        WHEN 'staff' THEN
            SELECT s.staff_id INTO v_id
            FROM   core.staff s
            WHERE  s.public_id  = p_public_id
              AND  s.tenant_id  = p_tenant_id
              AND  s.school_id  = p_school_id
              AND  s.is_deleted = FALSE;

        WHEN 'tc' THEN
            SELECT r.tc_id INTO v_id
            FROM   core.tc_register r
            WHERE  r.public_id = p_public_id
              AND  r.tenant_id = p_tenant_id
              AND  r.school_id = p_school_id;

        ELSE
            RAISE EXCEPTION 'fn_public_id_to_id: unknown entity %', p_entity
                USING ERRCODE = '22023';
    END CASE;

    RETURN v_id;   -- NULL = not found, or not this school's row
END;
$$;

-- ── 4. proc wrapper so the app can call it through PgExec ───────────────────
-- PgExec speaks procedures-with-refcursors; it has no scalar-function shape.
-- One row, one column: id (NULL when unresolved).
CREATE OR REPLACE PROCEDURE core.sp_resolve_public_id(
    p_entity     text,
    p_public_id  uuid,
    p_tenant_id  integer,
    p_school_id  integer,
    INOUT p_result refcursor DEFAULT 'resolve_public_id_cursor'::refcursor)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_result FOR
        SELECT core.fn_public_id_to_id(p_entity, p_public_id, p_tenant_id, p_school_id) AS id;
END;
$$;

COMMIT;

-- ============================================================================
-- AFTER RUNNING THIS
--
-- 1. Re-run these three scripts — they now also RETURN public_id so the app can
--    build links. The change is additive (one extra column in the result set);
--    a build that does not know the column simply ignores it, so an older
--    deployed build is unaffected:
--
--        student_list.sql          core.sp_student_list
--        staff_list.sql            core.sp_staff_list
--        sp_staff_manage.sql       core.sp_staff_manage        (LIST + GET)
--        transfer_certificate.sql  core.sp_transfer_certificate (List branch;
--                                  Print/Get already use SELECT r.*)
--
-- 2. Then wire the app: map public_id into the models, resolve the uuid from the
--    URL via core.sp_resolve_public_id, and switch the links. Do this only AFTER
--    the column exists in the shared database, or every link 404s.
--
-- WHAT THIS DOES NOT DO. A uuid hides the number; it does not authorise the
-- request. The tenant_id/school_id filters in every proc are what stop one
-- school reading another's data. Anyone who legitimately sees a record can copy
-- its uuid — so never drop those filters on the grounds that "the id is now
-- unguessable".
-- ============================================================================
