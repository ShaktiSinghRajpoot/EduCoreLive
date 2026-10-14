-- ============================================================================
-- Student data checks (Students › Data Checks).
--
-- Dirty records spoil every list and report (ID cards, admit cards, report
-- cards, attendance registers), so this page counts the active students of the
-- current session that fail each check and lists them for fixing. Read-only,
-- except AssignRolls, which numbers a section's students:
--     p_mode 'missing'  give the next free numbers to students without one
--     p_mode 'all'      renumber the whole section 1..n in name order
-- Like Edit Student, a roll change is written to core.students AND to the
-- session's core.student_enrolment row, with an admission_audit entry.
--
--   checks (key -> what is wrong)
--     no_roll, dup_roll, no_adm, dup_adm, no_dob, no_gender, no_guardian,
--     bad_mobile, no_section, no_photo, no_apaar
-- Re-runnable.
-- ============================================================================

CREATE OR REPLACE PROCEDURE core.sp_student_data_checks(
    IN    p_operation      varchar,          -- Summary | List | AssignRolls
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_check          varchar DEFAULT NULL,   -- List
    IN    p_class          varchar DEFAULT NULL,   -- AssignRolls
    IN    p_section        varchar DEFAULT NULL,
    IN    p_mode           varchar DEFAULT 'missing',
    INOUT p_result         refcursor DEFAULT 'data_checks_cursor')
LANGUAGE plpgsql
AS $$
DECLARE
    v_year  varchar;
    v_next  integer;
    v_count integer := 0;
    r       record;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    SELECT y.academic_year_name INTO v_year
      FROM academic.academic_years y
     WHERE y.tenant_id = p_tenant_id AND y.school_id = p_school_id
       AND COALESCE(y.is_current, FALSE) AND NOT COALESCE(y.is_deleted, FALSE)
     LIMIT 1;

    -- the active students of the session, with every check worked out once
    CREATE TEMP TABLE IF NOT EXISTS tmp_dc (student_id int, public_id uuid, student_name varchar, admission_no varchar,
        class_name varchar, section varchar, roll_no varchar, issue varchar, detail varchar) ON COMMIT DROP;
    TRUNCATE tmp_dc;

    IF p_operation IN ('Summary', 'List') THEN
        INSERT INTO tmp_dc
        SELECT s.student_id, s.public_id, s.student_name, s.admission_no, s.class_name, s.section, s.roll_no, x.issue, x.detail
          FROM core.students s
          CROSS JOIN LATERAL (VALUES
            ('no_roll',     NULLIF(trim(COALESCE(s.roll_no, '')), '') IS NULL, NULL::varchar),
            ('dup_roll',    NULLIF(trim(COALESCE(s.roll_no, '')), '') IS NOT NULL AND EXISTS (
                               SELECT 1 FROM core.students o
                                WHERE o.tenant_id = s.tenant_id AND o.school_id = s.school_id AND o.student_id <> s.student_id
                                  AND COALESCE(o.is_active, TRUE) AND o.academic_year = s.academic_year
                                  AND o.class_name = s.class_name AND lower(COALESCE(o.section, '')) = lower(COALESCE(s.section, ''))
                                  AND lower(trim(o.roll_no)) = lower(trim(s.roll_no))), 'Roll ' || s.roll_no),
            ('no_adm',      NULLIF(trim(COALESCE(s.admission_no, '')), '') IS NULL, NULL),
            ('dup_adm',     NULLIF(trim(COALESCE(s.admission_no, '')), '') IS NOT NULL AND EXISTS (
                               SELECT 1 FROM core.students o
                                WHERE o.tenant_id = s.tenant_id AND o.school_id = s.school_id AND o.student_id <> s.student_id
                                  AND lower(trim(o.admission_no)) = lower(trim(s.admission_no))), s.admission_no),
            ('no_dob',      NULLIF(trim(COALESCE(s.dob, '')), '') IS NULL, NULL),
            ('no_gender',   NULLIF(trim(COALESCE(s.gender, '')), '') IS NULL, NULL),
            ('no_guardian', NULLIF(trim(COALESCE(s.guardian_name, '')), '') IS NULL, NULL),
            ('bad_mobile',  length(regexp_replace(COALESCE(s.mobile, ''), '\D', '', 'g')) <> 10,
                            COALESCE(NULLIF(s.mobile, ''), 'none')),
            ('no_section',  NULLIF(trim(COALESCE(s.section, '')), '') IS NULL OR NOT EXISTS (
                               SELECT 1 FROM academic.academic_class_sections sec
                                 JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
                                 JOIN academic.academic_years y ON y.academic_year_id = c.academic_year_id
                                WHERE sec.tenant_id = s.tenant_id AND sec.school_id = s.school_id
                                  AND c.class_name = s.class_name AND lower(sec.section_name) = lower(COALESCE(s.section, ''))
                                  AND y.academic_year_name = s.academic_year AND NOT COALESCE(sec.is_deleted, FALSE)),
                            COALESCE(s.class_name, '?') || ' – ' || COALESCE(NULLIF(s.section, ''), 'no section')),
            ('no_photo',    NULLIF(trim(COALESCE(s.photo_url, '')), '') IS NULL, NULL),
            ('no_apaar',    NULLIF(trim(COALESCE(s.apaar_id, '')), '') IS NULL, NULL)
          ) AS x(issue, failed, detail)
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
           AND s.academic_year = v_year AND x.failed;
    END IF;

    -- ── Summary: one row per check, in the order the page shows them
    IF p_operation = 'Summary' THEN
        OPEN p_result FOR
        SELECT k.issue, k.label, k.hint, k.severity, k.ord,
               (SELECT COUNT(*) FROM tmp_dc t WHERE t.issue = k.issue)::int AS students,
               (SELECT COUNT(*) FROM core.students s WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id
                   AND COALESCE(s.is_active, TRUE) AND s.academic_year = v_year)::int AS total
          FROM (VALUES
            ('no_roll',     'No roll number',          'Attendance registers, admit cards and report cards sort by roll number.', 'fix',  1),
            ('dup_roll',    'Duplicate roll number',   'Two students of the same section share a roll number.',                  'fix',  2),
            ('no_adm',      'No admission number',     'Receipts, TC and ID cards need it.',                                      'fix',  3),
            ('dup_adm',     'Duplicate admission number', 'An admission number must be unique in the school.',                    'fix',  4),
            ('no_section',  'No valid section',        'The class or section is not set up for this session.',                   'fix',  5),
            ('bad_mobile',  'Mobile missing or not 10 digits', 'Reminders and WhatsApp cannot reach the family.',                'fix',  6),
            ('no_guardian', 'No father / guardian name', 'Certificates and report cards print it.',                              'fix',  7),
            ('no_dob',      'No date of birth',        'Certificates, ID cards and the TC print it.',                            'fix',  8),
            ('no_gender',   'No gender',               'Certificates use it for "son / daughter".',                              'fix',  9),
            ('no_photo',    'No photo',                'ID cards, admit cards and report cards show a blank box.',               'info', 10),
            ('no_apaar',    'No APAAR ID',             'Needed for UDISE+ / board registrations.',                               'info', 11)
          ) AS k(issue, label, hint, severity, ord)
         ORDER BY k.ord;
        RETURN;
    END IF;

    -- ── List: the students failing one check
    IF p_operation = 'List' THEN
        OPEN p_result FOR
        SELECT t.student_id, t.public_id, t.student_name, t.admission_no, t.class_name, t.section, t.roll_no, t.detail
          FROM tmp_dc t
          LEFT JOIN academic.academic_classes c ON c.tenant_id = p_tenant_id AND c.school_id = p_school_id
                                               AND c.class_name = t.class_name AND NOT COALESCE(c.is_deleted, FALSE)
         WHERE t.issue = p_check
         GROUP BY t.student_id, t.public_id, t.student_name, t.admission_no, t.class_name, t.section, t.roll_no, t.detail
         ORDER BY MIN(c.display_order) NULLS LAST, t.class_name, t.section,
                  NULLIF(regexp_replace(COALESCE(t.roll_no, ''), '\D', '', 'g'), '')::int NULLS LAST, t.student_name;
        RETURN;
    END IF;

    -- ── AssignRolls: number one section
    IF p_operation = 'AssignRolls' THEN
        IF NULLIF(trim(p_class), '') IS NULL THEN RAISE EXCEPTION 'Choose a class.'; END IF;
        IF COALESCE(p_mode, '') NOT IN ('missing', 'all') THEN RAISE EXCEPTION 'Choose how to number.'; END IF;

        -- 'missing' continues after the highest number already used in the section
        SELECT COALESCE(MAX(NULLIF(regexp_replace(COALESCE(s.roll_no, ''), '\D', '', 'g'), '')::int), 0)
          INTO v_next
          FROM core.students s
         WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
           AND s.academic_year = v_year AND s.class_name = trim(p_class)
           AND lower(COALESCE(s.section, '')) = lower(COALESCE(trim(p_section), ''));
        IF p_mode = 'all' THEN v_next := 0; END IF;

        FOR r IN
            SELECT s.student_id, s.roll_no
              FROM core.students s
             WHERE s.tenant_id = p_tenant_id AND s.school_id = p_school_id AND COALESCE(s.is_active, TRUE)
               AND s.academic_year = v_year AND s.class_name = trim(p_class)
               AND lower(COALESCE(s.section, '')) = lower(COALESCE(trim(p_section), ''))
               AND (p_mode = 'all' OR NULLIF(trim(COALESCE(s.roll_no, '')), '') IS NULL)
             ORDER BY lower(s.student_name), s.student_id
        LOOP
            v_next := v_next + 1;
            CONTINUE WHEN COALESCE(r.roll_no, '') = v_next::text;
            UPDATE core.students SET roll_no = v_next::text, updated_by = p_action_user_id, updated_at = now()
             WHERE student_id = r.student_id;
            UPDATE core.student_enrolment SET roll_no = v_next::text, updated_by = p_action_user_id, updated_at = now()
             WHERE student_id = r.student_id AND academic_year = v_year;
            INSERT INTO core.admission_audit (tenant_id, school_id, student_id, action, detail, action_by)
            VALUES (p_tenant_id, p_school_id, r.student_id, 'StudentEdited',
                    'Roll: ' || COALESCE(NULLIF(r.roll_no, ''), '-') || ' -> ' || v_next || ' (Data Checks: assign roll numbers)', p_action_user_id);
            v_count := v_count + 1;
        END LOOP;

        OPEN p_result FOR SELECT (CASE WHEN v_count = 0 THEN 'Nothing to change: every student already has that number.'
                                       ELSE 'Roll numbers set for ' || v_count || ' student(s).' END)::varchar AS message;
        RETURN;
    END IF;

    RAISE EXCEPTION 'Unknown operation.';
END;
$$;
