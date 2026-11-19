-- =====================================================================
-- Parent module, Phase 1 (view only) -- 19 Nov 2026
--
-- Parents sign in with a mobile number + one-time code and see their own
-- children (read only). See educore/docs/PARENT-MODULE.md.
--
--   * "Parent App" is the 10th sellable module: allow_parent_app (Super Admin)
--     AND enable_parent_app (school). Both OFF by default.
--   * The school chooses which parent screens show: parent_show_*.
--   * A child is linked when the student's Mobile or Alternate mobile equals the
--     parent's mobile. Worked out again on every request, so a changed number or a
--     block takes effect at once. Passed-out / left children stay (read only) for
--     12 months after their leaving date.
--   * core.parent_access_blocks: the school blocks one mobile from one child.
--   * core.parent_login_codes: the one-time code (hashed) and the wrong-code lock.
--   * core.parent_access_log: every parent login, receipt and report-card view.
--
-- Idempotent: safe to run again. No BEGIN/COMMIT (run with --single-transaction).
-- =====================================================================

-- ── 1. Module switches and per-screen switches ──────────────────────────
ALTER TABLE core.school_admission_workflow_settings
    ADD COLUMN IF NOT EXISTS allow_parent_app      boolean NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS enable_parent_app     boolean NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS parent_show_fees      boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS parent_show_receipts  boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS parent_show_results   boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS parent_show_homework  boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS parent_show_timetable boolean NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS parent_show_notices   boolean NOT NULL DEFAULT TRUE;

-- ── 2. Tables ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.parent_login_codes
(
    mobile        varchar(10) PRIMARY KEY,
    code_hash     varchar(64),
    expires_at    timestamptz,
    wrong_count   integer     NOT NULL DEFAULT 0,
    locked_until  timestamptz,
    last_sent_at  timestamptz,
    last_login_at timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz
);

CREATE TABLE IF NOT EXISTS core.parent_access_blocks
(
    block_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    integer     NOT NULL,
    school_id    integer     NOT NULL,
    student_id   integer     NOT NULL,
    mobile       varchar(10) NOT NULL,
    is_active    boolean     NOT NULL DEFAULT TRUE,
    blocked_by   integer,
    blocked_at   timestamptz NOT NULL DEFAULT now(),
    unblocked_by integer,
    unblocked_at timestamptz,
    CONSTRAINT uq_parent_access_block UNIQUE (student_id, mobile)
);

CREATE TABLE IF NOT EXISTS core.parent_access_log
(
    log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id  integer     NOT NULL,
    school_id  integer     NOT NULL,
    student_id integer     NOT NULL,
    mobile     varchar(10) NOT NULL,
    action     varchar(30) NOT NULL,      -- LOGIN / RECEIPT_VIEW / REPORT_CARD_VIEW
    detail     varchar(100),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_parent_access_log_school  ON core.parent_access_log (tenant_id, school_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_parent_access_log_student ON core.parent_access_log (student_id, action);

-- ── 3. Helpers ──────────────────────────────────────────────────────────
-- The last 10 digits of a phone number ("+91 98290-12345" -> "9829012345").
CREATE OR REPLACE FUNCTION core.fn_mobile10(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT right(regexp_replace(COALESCE(p_value, ''), '\D', '', 'g'), 10);
$$;

CREATE INDEX IF NOT EXISTS ix_students_mobile10     ON core.students (core.fn_mobile10(mobile));
CREATE INDEX IF NOT EXISTS ix_students_alt_mobile10 ON core.students (core.fn_mobile10(alt_mobile));

-- Parent App is on for a school: given by the platform, switched on by the
-- school, and the school itself can sign in (active, status allows login).
CREATE OR REPLACE FUNCTION core.fn_parent_app_on(p_tenant_id integer, p_school_id integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT w.allow_parent_app AND w.enable_parent_app
               AND sc.is_active AND NOT COALESCE(sc.is_deleted, FALSE)
               AND COALESCE(st.allows_login, FALSE)
          FROM core.school_admission_workflow_settings w
          JOIN core.schools sc ON sc.tenant_id = w.tenant_id AND sc.school_id = w.school_id
          LEFT JOIN config.school_statuses st ON st.school_status_id = sc.status_id AND st.is_deleted = FALSE
         WHERE w.tenant_id = p_tenant_id AND w.school_id = p_school_id
           AND NOT COALESCE(w.is_deleted, FALSE)
         LIMIT 1), FALSE);
$$;

-- ── 4. Children linked to a mobile ──────────────────────────────────────
-- The ONLY list a parent request may take a child from. Read on every request.
CREATE OR REPLACE PROCEDURE core.sp_parent_children(
    IN    p_mobile varchar,
    INOUT p_result refcursor DEFAULT 'parent_children_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_mobile text := core.fn_mobile10(p_mobile);
BEGIN
    IF length(v_mobile) <> 10 THEN
        OPEN p_result FOR SELECT NULL::int AS student_id WHERE FALSE;
        RETURN;
    END IF;

    OPEN p_result FOR
    WITH kids AS (
        SELECT s.*,
               CASE WHEN s.date_of_leaving ~ '^\d{4}-\d{2}-\d{2}$' THEN s.date_of_leaving::date
                    ELSE s.exit_recorded_at::date END AS left_on,
               core.fn_session_on(s.tenant_id, s.school_id, CURRENT_DATE) AS session_now
          FROM core.students s
         WHERE (core.fn_mobile10(s.mobile) = v_mobile OR core.fn_mobile10(s.alt_mobile) = v_mobile)
    )
    SELECT k.student_id, k.tenant_id, k.school_id,
           COALESCE(NULLIF(trim(sc.display_name), ''), sc.school_name) AS school_name,
           k.student_name, k.admission_no, k.photo_url,
           COALESCE(e.class_name, k.class_name)                    AS class_name,
           COALESCE(e.section, k.section)                          AS section,
           COALESCE(NULLIF(trim(e.roll_no), ''), k.roll_no)        AS roll_no,
           k.is_active                                             AS is_current,
           to_char(k.left_on, 'YYYY-MM-DD')                        AS left_on,
           CASE WHEN core.fn_mobile10(k.mobile) = v_mobile THEN 'Mobile' ELSE 'Alternate mobile' END AS relation,
           COALESCE(sec.academic_class_section_id, 0)              AS section_id,
           COALESCE(k.session_now, k.academic_year)                AS academic_year,
           tch.full_name                                           AS class_teacher,
           w.parent_show_fees, w.parent_show_receipts, w.parent_show_results,
           w.parent_show_homework, w.parent_show_timetable, w.parent_show_notices,
           (w.enable_fees       AND w.allow_fees)       AS fees_on,
           (w.enable_attendance AND w.allow_attendance) AS attendance_on,
           (w.enable_exams      AND w.allow_exams)      AS exams_on,
           (w.enable_academics  AND w.allow_academics)  AS academics_on
      FROM kids k
      JOIN core.schools sc ON sc.tenant_id = k.tenant_id AND sc.school_id = k.school_id
      JOIN core.school_admission_workflow_settings w ON w.tenant_id = k.tenant_id AND w.school_id = k.school_id
      LEFT JOIN core.student_enrolment e ON e.student_id = k.student_id AND e.academic_year = k.session_now
      LEFT JOIN academic.academic_years y ON y.tenant_id = k.tenant_id AND y.school_id = k.school_id
                                         AND y.academic_year_name = k.session_now AND NOT COALESCE(y.is_deleted, FALSE)
      LEFT JOIN academic.academic_classes c ON c.tenant_id = k.tenant_id AND c.school_id = k.school_id
                                           AND c.academic_year_id = y.academic_year_id
                                           AND c.class_name = COALESCE(e.class_name, k.class_name)
      LEFT JOIN academic.academic_class_sections sec ON sec.academic_class_id = c.academic_class_id
                                                    AND lower(sec.section_name) = lower(COALESCE(e.section, k.section, ''))
                                                    AND NOT COALESCE(sec.is_deleted, FALSE)
      LEFT JOIN core.staff tch ON tch.staff_id = sec.class_teacher_staff_id
     WHERE core.fn_parent_app_on(k.tenant_id, k.school_id)
       -- current pupils, or ones who left within the last 12 months (read only)
       AND (k.is_active OR (k.left_on IS NOT NULL AND k.left_on >= CURRENT_DATE - INTERVAL '12 months'))
       -- the school blocked this mobile for this child
       AND NOT EXISTS (SELECT 1 FROM core.parent_access_blocks b
                        WHERE b.student_id = k.student_id AND b.mobile = v_mobile AND b.is_active)
     ORDER BY k.is_active DESC, school_name, k.student_name, k.student_id;
END;
$procedure$;

-- ── 5. One-time code ────────────────────────────────────────────────────
-- Issue : store the code's hash (10 minutes). Says LOCKED while the mobile is locked.
-- Verify: OK / INVALID / EXPIRED / LOCKED. 5 wrong codes lock the mobile for 15 minutes.
--         INVALID also covers "right code but no child linked", so the reply never
--         tells which numbers are on a student record.
CREATE OR REPLACE PROCEDURE core.sp_parent_login_code(
    IN    p_operation varchar,
    IN    p_mobile    varchar,
    IN    p_code_hash varchar,
    INOUT p_result    refcursor DEFAULT 'parent_code_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_mobile text := core.fn_mobile10(p_mobile);
    v_row    core.parent_login_codes%ROWTYPE;
    v_linked boolean;
    v_status text;
    v_wait   integer := 0;
BEGIN
    IF length(v_mobile) <> 10 THEN
        OPEN p_result FOR SELECT 'INVALID'::text AS status, 0 AS wait_minutes, FALSE AS has_children;
        RETURN;
    END IF;

    INSERT INTO core.parent_login_codes (mobile) VALUES (v_mobile) ON CONFLICT (mobile) DO NOTHING;
    SELECT * INTO v_row FROM core.parent_login_codes WHERE mobile = v_mobile FOR UPDATE;

    IF v_row.locked_until IS NOT NULL AND v_row.locked_until > now() THEN
        v_wait := GREATEST(1, ceil(extract(epoch FROM v_row.locked_until - now()) / 60.0)::int);
        OPEN p_result FOR SELECT 'LOCKED'::text AS status, v_wait AS wait_minutes, FALSE AS has_children;
        RETURN;
    END IF;

    -- linked = at least one child the parent may see right now
    SELECT EXISTS (
        SELECT 1 FROM core.students s
         WHERE (core.fn_mobile10(s.mobile) = v_mobile OR core.fn_mobile10(s.alt_mobile) = v_mobile)
           AND core.fn_parent_app_on(s.tenant_id, s.school_id)
           AND (s.is_active OR (CASE WHEN s.date_of_leaving ~ '^\d{4}-\d{2}-\d{2}$' THEN s.date_of_leaving::date
                                     ELSE s.exit_recorded_at::date END) >= CURRENT_DATE - INTERVAL '12 months')
           AND NOT EXISTS (SELECT 1 FROM core.parent_access_blocks b
                            WHERE b.student_id = s.student_id AND b.mobile = v_mobile AND b.is_active))
      INTO v_linked;

    IF p_operation = 'Issue' THEN
        UPDATE core.parent_login_codes
           SET code_hash = p_code_hash, expires_at = now() + INTERVAL '10 minutes',
               locked_until = NULL, last_sent_at = now(), updated_at = now()
         WHERE mobile = v_mobile;
        OPEN p_result FOR SELECT 'OK'::text AS status, 0 AS wait_minutes, v_linked AS has_children;
        RETURN;
    END IF;

    IF p_operation <> 'Verify' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    IF v_row.code_hash IS NOT NULL AND v_row.code_hash = p_code_hash AND v_linked THEN
        IF v_row.expires_at < now() THEN
            v_status := 'EXPIRED';
            UPDATE core.parent_login_codes SET code_hash = NULL, updated_at = now() WHERE mobile = v_mobile;
        ELSE
            v_status := 'OK';
            UPDATE core.parent_login_codes
               SET code_hash = NULL, expires_at = NULL, wrong_count = 0, locked_until = NULL,
                   last_login_at = now(), updated_at = now()
             WHERE mobile = v_mobile;
        END IF;
    ELSE
        IF v_row.wrong_count + 1 >= 5 THEN
            v_status := 'LOCKED';
            v_wait   := 15;
            UPDATE core.parent_login_codes
               SET wrong_count = 0, code_hash = NULL, locked_until = now() + INTERVAL '15 minutes', updated_at = now()
             WHERE mobile = v_mobile;
        ELSE
            v_status := 'INVALID';
            UPDATE core.parent_login_codes SET wrong_count = wrong_count + 1, updated_at = now() WHERE mobile = v_mobile;
        END IF;
    END IF;

    OPEN p_result FOR SELECT v_status AS status, v_wait AS wait_minutes, v_linked AS has_children;
END;
$procedure$;

-- ── 6. Audit: one row per login per child, and per receipt / report card view
CREATE OR REPLACE PROCEDURE core.sp_parent_access_log_add(
    IN p_tenant_id  integer,
    IN p_school_id  integer,
    IN p_student_id integer,
    IN p_mobile     varchar,
    IN p_action     varchar,
    IN p_detail     varchar DEFAULT NULL)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        RETURN;
    END IF;
    INSERT INTO core.parent_access_log (tenant_id, school_id, student_id, mobile, action, detail)
    VALUES (p_tenant_id, p_school_id, p_student_id, core.fn_mobile10(p_mobile), left(p_action, 30), left(p_detail, 100));
END;
$procedure$;

-- ── 7. Notices for a parent: to everyone, to parents, or to the child's class
CREATE OR REPLACE PROCEDURE core.sp_parent_notices(
    IN    p_tenant_id  integer,
    IN    p_school_id  integer,
    IN    p_class_name varchar,
    INOUT p_result     refcursor DEFAULT 'parent_notices_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_result FOR
    SELECT a.announcement_id, a.title, a.body, a.category, a.is_pinned,
           to_char(a.created_at, 'YYYY-MM-DD') AS posted_on
      FROM core.announcements a
     WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id AND NOT a.is_deleted
       AND (a.show_until IS NULL OR a.show_until >= CURRENT_DATE)
       AND (a.audience IN ('Everyone', 'Parents')
            OR (a.audience = 'Classes'
                AND lower(trim(COALESCE(p_class_name, ''))) = ANY (
                    SELECT lower(trim(x)) FROM unnest(string_to_array(COALESCE(a.class_names, ''), ',')) x)))
     ORDER BY a.is_pinned DESC, a.created_at DESC
     LIMIT 50;
END;
$procedure$;

-- ── 8. Student profile > Parent access (school staff) ───────────────────
-- Get    : the child's two mobiles, blocked or not, and their last parent login.
-- Block / Unblock : one mobile for this child only; the student record is not touched.
CREATE OR REPLACE PROCEDURE core.sp_parent_access_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_student_id     integer,
    IN    p_mobile         varchar DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'parent_access_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_mobile text := core.fn_mobile10(p_mobile);
    v_name   text;
    v_m1     text;
    v_m2     text;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 OR COALESCE(p_student_id, 0) <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT s.student_name, core.fn_mobile10(s.mobile), core.fn_mobile10(s.alt_mobile)
      INTO v_name, v_m1, v_m2
      FROM core.students s
     WHERE s.student_id = p_student_id AND s.tenant_id = p_tenant_id AND s.school_id = p_school_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found.';
    END IF;

    IF p_operation IN ('Block', 'Unblock') THEN
        IF length(v_mobile) <> 10 OR v_mobile NOT IN (COALESCE(v_m1, ''), COALESCE(v_m2, '')) THEN
            RAISE EXCEPTION 'This mobile is not on the student''s record.';
        END IF;

        IF p_operation = 'Block' THEN
            INSERT INTO core.parent_access_blocks (tenant_id, school_id, student_id, mobile, is_active, blocked_by, blocked_at)
            VALUES (p_tenant_id, p_school_id, p_student_id, v_mobile, TRUE, p_action_user_id, now())
            ON CONFLICT (student_id, mobile) DO UPDATE
               SET is_active = TRUE, blocked_by = p_action_user_id, blocked_at = now(),
                   unblocked_by = NULL, unblocked_at = NULL;
        ELSE
            UPDATE core.parent_access_blocks
               SET is_active = FALSE, unblocked_by = p_action_user_id, unblocked_at = now()
             WHERE student_id = p_student_id AND mobile = v_mobile AND is_active;
        END IF;

        PERFORM core.fn_admin_audit(p_tenant_id, p_school_id, p_action_user_id,
            CASE p_operation WHEN 'Block' THEN 'PARENT_ACCESS_BLOCK' ELSE 'PARENT_ACCESS_UNBLOCK' END,
            'Students/Profile', 'core.parent_access_blocks', p_student_id,
            format('%s parent access of %s for %s (student %s)',
                   CASE p_operation WHEN 'Block' THEN 'Blocked' ELSE 'Unblocked' END,
                   'XXXXXX' || right(v_mobile, 4), v_name, p_student_id));
    ELSIF p_operation <> 'Get' THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT m.label, m.mobile,
           EXISTS (SELECT 1 FROM core.parent_access_blocks b
                    WHERE b.student_id = p_student_id AND b.mobile = m.mobile AND b.is_active) AS is_blocked,
           (SELECT to_char(max(l.created_at), 'YYYY-MM-DD HH24:MI') FROM core.parent_access_log l
             WHERE l.student_id = p_student_id AND l.mobile = m.mobile AND l.action = 'LOGIN') AS last_login,
           core.fn_parent_app_on(p_tenant_id, p_school_id) AS parent_app_on
      FROM (VALUES (1, 'Mobile', v_m1), (2, 'Alternate mobile', v_m2)) AS m(ord, label, mobile)
     WHERE length(COALESCE(m.mobile, '')) = 10
       -- the same number twice on one record is one parent
       AND NOT (m.ord = 2 AND m.mobile = v_m1)
     ORDER BY m.ord;
END;
$procedure$;

-- ── 9. Report: Parent logins (School Admin) ─────────────────────────────
-- 1: per class-section of current pupils: how many have a parent who has logged in.
-- 2: the latest 300 parent logins and receipt / report-card views.
-- 3: current pupils whose parents have never logged in.
CREATE OR REPLACE PROCEDURE core.sp_parent_login_report(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    INOUT p_classes        refcursor DEFAULT 'parent_report_classes'::refcursor,
    INOUT p_log            refcursor DEFAULT 'parent_report_log'::refcursor,
    INOUT p_never          refcursor DEFAULT 'parent_report_never'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    OPEN p_classes FOR
    SELECT s.class_name, COALESCE(s.section, '') AS section,
           COUNT(*)::int AS students,
           COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM core.parent_access_log l
                                           WHERE l.student_id = s.student_id AND l.action = 'LOGIN'))::int AS logged_in
      FROM core.students s
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
     GROUP BY s.class_name, COALESCE(s.section, '')
     ORDER BY length(s.class_name), s.class_name, 2;

    OPEN p_log FOR
    SELECT to_char(l.created_at, 'YYYY-MM-DD HH24:MI') AS at_time,
           l.mobile, l.action, COALESCE(l.detail, '') AS detail,
           s.student_name, s.class_name, COALESCE(s.section, '') AS section
      FROM core.parent_access_log l
      JOIN core.students s ON s.student_id = l.student_id
     WHERE l.tenant_id = p_tenant_id AND l.school_id = p_school_id
     ORDER BY l.created_at DESC
     LIMIT 300;

    OPEN p_never FOR
    SELECT s.student_name, s.class_name, COALESCE(s.section, '') AS section, COALESCE(s.roll_no, '') AS roll_no
      FROM core.students s
     WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND s.is_active
       AND NOT EXISTS (SELECT 1 FROM core.parent_access_log l
                        WHERE l.student_id = s.student_id AND l.action = 'LOGIN')
     ORDER BY length(s.class_name), s.class_name, s.section, s.student_name
     LIMIT 1000;
END;
$procedure$;

-- ── 10. School: Parent App switch and parent screens (Modules & Workflow) ─
CREATE OR REPLACE PROCEDURE core.sp_parent_app_settings_save(
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_enable         boolean,
    IN    p_fees           boolean,
    IN    p_receipts       boolean,
    IN    p_results        boolean,
    IN    p_homework       boolean,
    IN    p_timetable      boolean,
    IN    p_notices        boolean,
    INOUT p_result         refcursor DEFAULT 'parent_settings_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    -- not given by the platform: nothing of it can be changed by the school
    UPDATE core.school_admission_workflow_settings
       SET enable_parent_app     = COALESCE(p_enable,    enable_parent_app),
           parent_show_fees      = COALESCE(p_fees,      parent_show_fees),
           parent_show_receipts  = COALESCE(p_receipts,  parent_show_receipts),
           parent_show_results   = COALESCE(p_results,   parent_show_results),
           parent_show_homework  = COALESCE(p_homework,  parent_show_homework),
           parent_show_timetable = COALESCE(p_timetable, parent_show_timetable),
           parent_show_notices   = COALESCE(p_notices,   parent_show_notices),
           updated_by = p_action_user_id, updated_at = now()
     WHERE tenant_id = p_tenant_id AND school_id = p_school_id
       AND allow_parent_app;

    OPEN p_result FOR SELECT FOUND AS success;
END;
$procedure$;

-- ── 11. Super Admin: give / take away Parent App ────────────────────────
CREATE OR REPLACE PROCEDURE core.sp_superadmin_parent_app(
    IN    p_operation      varchar,
    IN    p_action_user_id integer,
    IN    p_school_id      integer,
    IN    p_allow          boolean DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'parent_app_cursor'::refcursor)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_tenant integer;
    v_name   text;
    v_before boolean;
BEGIN
    IF NOT core.fn_is_super_admin(p_action_user_id) THEN
        RAISE EXCEPTION 'Only the Super Admin can change the modules of a school.';
    END IF;

    SELECT tenant_id, school_name INTO v_tenant, v_name
      FROM core.schools WHERE school_id = p_school_id AND NOT COALESCE(is_deleted, FALSE);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'School not found.';
    END IF;

    IF p_operation = 'Save' AND p_allow IS NOT NULL THEN
        SELECT allow_parent_app INTO v_before
          FROM core.school_admission_workflow_settings
         WHERE tenant_id = v_tenant AND school_id = p_school_id;

        INSERT INTO core.school_admission_workflow_settings (tenant_id, school_id, allow_parent_app, created_by)
        VALUES (v_tenant, p_school_id, p_allow, p_action_user_id)
        ON CONFLICT (tenant_id, school_id) DO UPDATE
           SET allow_parent_app = EXCLUDED.allow_parent_app,
               updated_by = p_action_user_id, updated_at = now();

        IF COALESCE(v_before, FALSE) IS DISTINCT FROM p_allow THEN
            PERFORM core.fn_admin_audit(1, NULL, p_action_user_id, 'SCHOOL_MODULES_CHANGE', 'SuperAdmin/Schools',
                'core.school_admission_workflow_settings', p_school_id,
                format('Parent App %s %s (school %s)',
                       CASE WHEN p_allow THEN 'given to' ELSE 'taken away from' END, v_name, p_school_id));
        END IF;
    ELSIF p_operation NOT IN ('Get', 'Save') THEN
        RAISE EXCEPTION 'Unknown operation %.', p_operation;
    END IF;

    OPEN p_result FOR
    SELECT COALESCE(w.allow_parent_app, FALSE)  AS allow_parent_app,
           COALESCE(w.enable_parent_app, FALSE) AS enable_parent_app
      FROM (SELECT 1) one
      LEFT JOIN core.school_admission_workflow_settings w
             ON w.tenant_id = v_tenant AND w.school_id = p_school_id;
END;
$procedure$;

-- ── 12. Modules & Workflow read: adds the Parent App columns (same signature) ──
CREATE OR REPLACE PROCEDURE core.sp_school_admin_admission_workflow_manage(IN p_operation character varying, IN p_tenant_id integer, IN p_school_id integer, IN p_action_user_id integer, IN p_enable_registration boolean DEFAULT NULL::boolean, IN p_registration_required_before_admission boolean DEFAULT NULL::boolean, IN p_enable_registration_fee boolean DEFAULT NULL::boolean, IN p_auto_generate_registration_number boolean DEFAULT NULL::boolean, IN p_registration_number_prefix character varying DEFAULT NULL::character varying, IN p_collect_fee_at_admission boolean DEFAULT NULL::boolean, IN p_enable_security_fee boolean DEFAULT NULL::boolean, IN p_enable_transport boolean DEFAULT NULL::boolean, IN p_enable_exams boolean DEFAULT NULL::boolean, IN p_enable_inventory boolean DEFAULT NULL::boolean, IN p_enable_payroll boolean DEFAULT NULL::boolean, IN p_enable_attendance boolean DEFAULT NULL::boolean, IN p_enable_academics boolean DEFAULT NULL::boolean, IN p_enable_fees boolean DEFAULT NULL::boolean, IN p_enable_accounts boolean DEFAULT NULL::boolean, INOUT p_result refcursor DEFAULT 'result_cursor'::refcursor)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_enable_reg   boolean;
    v_required     boolean;
    v_enable_fee   boolean;
    v_auto_num     boolean;
    v_prefix       varchar(20);
    v_collect      boolean;
    v_enable_sec   boolean;
    v_enable_trans boolean;
    v_enable_exam  boolean;
    v_enable_inv   boolean;
    v_enable_pay   boolean;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school admin scope.';
    END IF;

    IF p_operation = 'GetAdmissionWorkflow' THEN
        OPEN p_result FOR
        SELECT
            enable_registration,
            registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number,
            registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            -- a module is on only when the Super Admin gave it AND the school switched it on
            enable_transport  AND allow_transport  AS enable_transport,
            enable_exams      AND allow_exams      AS enable_exams,
            enable_inventory  AND allow_inventory  AS enable_inventory,
            enable_payroll    AND allow_payroll    AS enable_payroll,
            enable_attendance AND allow_attendance AS enable_attendance,
            enable_academics  AND allow_academics  AS enable_academics,
            enable_fees       AND allow_fees       AS enable_fees,
            enable_accounts   AND allow_accounts   AS enable_accounts,
            allow_transport, allow_exams, allow_inventory, allow_payroll,
            allow_attendance, allow_academics, allow_fees, allow_accounts,
            -- Parent App (parent_module.sql): on = given AND switched on; and the parent screens
            enable_parent_app AND allow_parent_app AS enable_parent_app,
            allow_parent_app,
            parent_show_fees, parent_show_receipts, parent_show_results,
            parent_show_homework, parent_show_timetable, parent_show_notices
        FROM core.school_admission_workflow_settings
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id
          AND COALESCE(is_deleted, FALSE) = FALSE
        LIMIT 1;

    ELSIF p_operation = 'SaveAdmissionWorkflow' THEN
        v_enable_reg   := COALESCE(p_enable_registration, FALSE);
        v_required     := v_enable_reg AND COALESCE(p_registration_required_before_admission, FALSE);
        v_enable_fee   := v_enable_reg AND COALESCE(p_enable_registration_fee, FALSE);
        v_auto_num     := COALESCE(p_auto_generate_registration_number, TRUE);
        v_prefix       := COALESCE(NULLIF(trim(p_registration_number_prefix), ''), 'REG-');
        v_collect      := COALESCE(p_collect_fee_at_admission, FALSE);
        v_enable_sec   := COALESCE(p_enable_security_fee, FALSE);
        v_enable_trans := COALESCE(p_enable_transport, TRUE);
        v_enable_exam  := COALESCE(p_enable_exams, TRUE);
        v_enable_inv   := COALESCE(p_enable_inventory, TRUE);
        v_enable_pay   := COALESCE(p_enable_payroll, TRUE);

        -- Transport cannot be switched off while children still ride or owe bus
        -- fees: those dues would stay on the fee counter with no module behind them.
        IF NOT v_enable_trans AND core.fn_module_on(p_tenant_id, p_school_id, 'transport') THEN
            IF EXISTS (SELECT 1 FROM core.student_transport a
                         JOIN core.students st ON st.student_id = a.student_id AND st.is_active
                        WHERE a.tenant_id = p_tenant_id AND a.school_id = p_school_id
                          AND a.is_active AND NOT COALESCE(a.is_deleted, FALSE))
               OR EXISTS (SELECT 1 FROM core.student_ledger
                           WHERE tenant_id = p_tenant_id AND school_id = p_school_id
                             AND fee_head_name = 'Transport Fee'
                             AND amount_due - amount_paid - COALESCE(concession, 0) > 0) THEN
                RAISE EXCEPTION 'Transport cannot be turned off while students are on buses or owe bus fees. End their bus assignments (Transport > Assign Transport) first.';
            END IF;
        END IF;

        INSERT INTO core.school_admission_workflow_settings
        (
            tenant_id, school_id,
            enable_registration, registration_required_before_admission,
            enable_registration_fee,
            auto_generate_registration_number, registration_number_prefix,
            collect_fee_at_admission,
            enable_security_fee,
            enable_transport,
            enable_exams,
            enable_inventory,
            enable_payroll,
            enable_attendance,
            enable_academics,
            enable_fees,
            enable_accounts,
            created_by, created_at, is_deleted, is_active
        )
        VALUES
        (
            p_tenant_id, p_school_id,
            v_enable_reg, v_required,
            v_enable_fee,
            v_auto_num, v_prefix,
            v_collect,
            v_enable_sec,
            v_enable_trans,
            v_enable_exam,
            v_enable_inv,
            v_enable_pay,
            COALESCE(p_enable_attendance, TRUE),
            COALESCE(p_enable_academics, TRUE),
            COALESCE(p_enable_fees, TRUE),
            COALESCE(p_enable_accounts, TRUE),
            p_action_user_id, NOW(), FALSE, TRUE
        )
        ON CONFLICT (tenant_id, school_id) DO UPDATE
        SET enable_registration                    = EXCLUDED.enable_registration,
            registration_required_before_admission = EXCLUDED.registration_required_before_admission,
            enable_registration_fee                = EXCLUDED.enable_registration_fee,
            auto_generate_registration_number      = EXCLUDED.auto_generate_registration_number,
            registration_number_prefix             = EXCLUDED.registration_number_prefix,
            collect_fee_at_admission               = EXCLUDED.collect_fee_at_admission,
            enable_security_fee                    = EXCLUDED.enable_security_fee,
            -- a module the Super Admin has not given keeps its stored switch
            enable_transport = CASE WHEN school_admission_workflow_settings.allow_transport
                                    THEN EXCLUDED.enable_transport ELSE school_admission_workflow_settings.enable_transport END,
            enable_exams     = CASE WHEN school_admission_workflow_settings.allow_exams
                                    THEN EXCLUDED.enable_exams ELSE school_admission_workflow_settings.enable_exams END,
            enable_inventory = CASE WHEN school_admission_workflow_settings.allow_inventory
                                    THEN EXCLUDED.enable_inventory ELSE school_admission_workflow_settings.enable_inventory END,
            enable_payroll   = CASE WHEN school_admission_workflow_settings.allow_payroll
                                    THEN EXCLUDED.enable_payroll ELSE school_admission_workflow_settings.enable_payroll END,
            -- the newer modules: not sent (NULL) or not given = keep the stored switch
            enable_attendance = CASE WHEN school_admission_workflow_settings.allow_attendance AND p_enable_attendance IS NOT NULL
                                     THEN p_enable_attendance ELSE school_admission_workflow_settings.enable_attendance END,
            enable_academics  = CASE WHEN school_admission_workflow_settings.allow_academics AND p_enable_academics IS NOT NULL
                                     THEN p_enable_academics ELSE school_admission_workflow_settings.enable_academics END,
            enable_fees       = CASE WHEN school_admission_workflow_settings.allow_fees AND p_enable_fees IS NOT NULL
                                     THEN p_enable_fees ELSE school_admission_workflow_settings.enable_fees END,
            enable_accounts   = CASE WHEN school_admission_workflow_settings.allow_accounts AND p_enable_accounts IS NOT NULL
                                     THEN p_enable_accounts ELSE school_admission_workflow_settings.enable_accounts END,
            is_deleted = FALSE, is_active = TRUE,
            updated_by = p_action_user_id, updated_at = NOW();

        OPEN p_result FOR SELECT TRUE AS success, 'Saved successfully.' AS message;
    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$

;
