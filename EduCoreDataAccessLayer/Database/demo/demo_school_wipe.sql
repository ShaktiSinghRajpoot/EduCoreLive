-- ============================================================================
-- Wipe a DEMO school's data, keeping the school itself and its logins.
--
--   psql -v school=45 -v confirm="Angel's Paradise School" -v ON_ERROR_STOP=1 --single-transaction -f demo_school_wipe.sql
--
-- Kept: the school, its profile / address / contacts / documents / settings /
-- module switches / WhatsApp switch, its users with their roles and sessions,
-- and its roles + permissions. Everything else of that school is deleted:
-- sessions, classes, subjects, students, staff, fees, attendance, exams,
-- timetable, transport, inventory, enquiries, notices, expenses, logs.
--
-- Only for a demo / test school: -v confirm must be the school's exact name
-- (as for the Super Admin's purge), so it can never run against a real school by mistake.
-- ============================================================================

\set ON_ERROR_STOP 1
SELECT set_config('demo.school', :'school', false);
SELECT set_config('demo.confirm', :'confirm', false);

DO $$
DECLARE
    v_school  integer := current_setting('demo.school')::integer;
    v_tenant  integer;
    v_name    text;
    r         record;
    v_has_school boolean;
BEGIN
    SELECT tenant_id, school_name INTO v_tenant, v_name FROM core.schools WHERE school_id = v_school;
    IF v_name IS NULL THEN RAISE EXCEPTION 'School % not found.', v_school; END IF;
    IF v_name <> current_setting('demo.confirm') THEN
        RAISE EXCEPTION 'Refusing to wipe "%": -v confirm must be the school''s exact name.', v_name;
    END IF;

    -- Rows are removed table by table; foreign keys are checked at the end of
    -- the transaction only for what is left, so the order does not matter here.
    SET LOCAL session_replication_role = replica;

    -- child tables without their own school column
    DELETE FROM core.fee_payment_details d USING core.fee_payments p WHERE d.payment_id = p.payment_id AND p.school_id = v_school;
    DELETE FROM core.fee_payment_tenders d USING core.fee_payments p WHERE d.payment_id = p.payment_id AND p.school_id = v_school;
    DELETE FROM core.inventory_student_sale_lines l USING core.inventory_student_sales s WHERE l.sale_id = s.sale_id AND s.school_id = v_school;
    DELETE FROM academic.homework_status h USING academic.homework w WHERE h.homework_id = w.homework_id AND w.school_id = v_school;
    DELETE FROM core.announcement_reads x USING core.announcements a WHERE x.announcement_id = a.announcement_id AND a.school_id = v_school;

    FOR r IN
        SELECT c.table_schema s, c.table_name t, bool_or(c.column_name = 'school_id') has_school
          FROM information_schema.columns c
          JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name AND tb.table_type = 'BASE TABLE'
         WHERE c.table_schema IN ('core', 'academic', 'config')
         GROUP BY 1, 2
        HAVING bool_or(c.column_name IN ('tenant_id', 'school_id'))
    LOOP
        CONTINUE WHEN r.s || '.' || r.t IN (
            'core.schools', 'core.tenants',
            'core.school_profiles', 'core.school_addresses', 'core.school_contacts', 'core.school_documents',
            'core.school_settings', 'core.school_working_hours', 'core.school_admission_workflow_settings',
            'core.school_messaging',
            'core.users', 'core.user_profiles', 'core.user_roles', 'core.user_sessions',
            'core.login_attempts', 'core.password_reset_tokens',
            'config.roles', 'config.role_permissions',
            'core.superadmin_login_as_log');
        IF r.has_school THEN
            EXECUTE format('DELETE FROM %I.%I WHERE school_id = $1', r.s, r.t) USING v_school;
        ELSE
            -- tenant-level masters (departments, designations): one school per demo tenant
            EXECUTE format('DELETE FROM %I.%I WHERE tenant_id = $1', r.s, r.t) USING v_tenant;
        END IF;
    END LOOP;

    RAISE NOTICE 'Wiped school % (%).', v_school, v_name;
END $$;
