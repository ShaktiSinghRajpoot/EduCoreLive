-- ============================================================================
-- Deploy the Classes & Sections hardening (tenant scoping + duplicate guard).
--
-- Run from THIS directory so the \i paths resolve:
--     psql "<connection string>" -v ON_ERROR_STOP=1 -f classsection_hardening_deploy.sql
--
-- Everything here is re-runnable. Step 3 refuses to create the unique indexes
-- if duplicates already exist, and names them, rather than failing halfway.
--
-- The application code ships separately. Deploying this script first is safe:
-- the procedure's signature and result columns are unchanged, so the currently
-- deployed build keeps working against it.
-- ============================================================================

\echo ''
\echo '== 0/3  where are we =='
SELECT current_database() AS db, version() AS server;

\echo ''
\echo '== keep this: the procedure as it is RIGHT NOW (rollback copy) =='
SELECT pg_get_functiondef(p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'academic'
   AND p.proname = 'sp_school_admin_academic_setup_manage';

\echo ''
\echo '== 1/3  duplicate check (must be empty before step 3) =='
SELECT ac.tenant_id, ac.school_id, ac.academic_year_id, ac.class_name,
       lower(acs.section_name) AS section, count(*) AS copies
  FROM academic.academic_class_sections acs
  JOIN academic.academic_classes ac
       ON ac.academic_class_id = acs.academic_class_id
 WHERE COALESCE(acs.is_deleted, FALSE) = FALSE
   AND COALESCE(ac.is_deleted, FALSE) = FALSE
 GROUP BY 1,2,3,4,5 HAVING count(*) > 1
 ORDER BY 1,2,3,4;

SELECT tenant_id, school_id, academic_year_id, lower(class_name) AS class,
       count(*) AS copies
  FROM academic.academic_classes
 WHERE COALESCE(is_deleted, FALSE) = FALSE
 GROUP BY 1,2,3,4 HAVING count(*) > 1
 ORDER BY 1,2,3;

\echo ''
\echo '== 2/3  procedure: tenant scoping on read, save and coordinator =='
\i academic_class_section_fields.sql

\echo ''
\echo '== 3/3  unique indexes (skipped, with a list, if duplicates exist) =='
DO $deploy$
DECLARE
    v_dup_sections integer;
    v_dup_classes  integer;
BEGIN
    SELECT count(*) INTO v_dup_sections FROM (
        SELECT 1 FROM academic.academic_class_sections acs
          JOIN academic.academic_classes ac
               ON ac.academic_class_id = acs.academic_class_id
         WHERE COALESCE(acs.is_deleted, FALSE) = FALSE
           AND COALESCE(ac.is_deleted, FALSE) = FALSE
         GROUP BY ac.tenant_id, ac.school_id, ac.academic_year_id,
                  ac.class_name, lower(acs.section_name)
        HAVING count(*) > 1) d;

    SELECT count(*) INTO v_dup_classes FROM (
        SELECT 1 FROM academic.academic_classes
         WHERE COALESCE(is_deleted, FALSE) = FALSE
         GROUP BY tenant_id, school_id, academic_year_id, lower(class_name)
        HAVING count(*) > 1) d;

    IF v_dup_sections > 0 OR v_dup_classes > 0 THEN
        RAISE WARNING 'Indexes NOT created: % duplicate class group(s), % duplicate section group(s). See step 1 output; fix them by hand (renaming a section moves the students enrolled under the old name), then re-run this script.',
              v_dup_classes, v_dup_sections;
    ELSE
        CREATE UNIQUE INDEX IF NOT EXISTS ux_academic_classes_name
            ON academic.academic_classes
               (tenant_id, school_id, academic_year_id, lower(class_name))
            WHERE COALESCE(is_deleted, FALSE) = FALSE;

        CREATE UNIQUE INDEX IF NOT EXISTS ux_academic_class_sections_name
            ON academic.academic_class_sections
               (academic_class_id, lower(section_name))
            WHERE COALESCE(is_deleted, FALSE) = FALSE;

        RAISE NOTICE 'Unique indexes are in place.';
    END IF;
END $deploy$;

\echo ''
\echo '== verify: all four must say true =='
SELECT
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname='academic' AND p.proname='sp_school_admin_academic_setup_manage'
        AND pg_get_functiondef(p.oid) LIKE '%AND ay.tenant_id = p_tenant_id%') = 1
        AS read_path_scoped,
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname='academic' AND p.proname='sp_school_admin_academic_setup_manage'
        AND pg_get_functiondef(p.oid) LIKE '%IF v_coordinator IS NULL THEN%') = 1
        AS coordinator_scoped,
    (SELECT to_regclass('academic.ux_academic_classes_name') IS NOT NULL)
        AS class_index,
    (SELECT to_regclass('academic.ux_academic_class_sections_name') IS NOT NULL)
        AS section_index;
