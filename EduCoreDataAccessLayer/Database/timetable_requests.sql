-- ============================================================================
-- Timetable requests: a teacher asks for a period, an admin approves it.
--
-- WHY: the timetable used to be built by the admin alone. A teacher knows their
-- own load best, so a teacher now REQUESTS a period (section + subject in a
-- day / period slot) from "My Timetable", and an admin approves or rejects it on
-- the Timetable page. The admin can still edit the timetable directly.
--
-- HOW (kept simple):
--   * academic.timetable stays the LIVE timetable and is untouched. Everything
--     that reads it (student dashboard, attendance, marks-entry scope) keeps
--     working, and a pending request is never visible there.
--   * Requests live in their own table, so a change to an approved period can
--     wait for approval while the old period stays live.
--   * Approve calls the existing SaveCell, so every timetable rule (weekly off,
--     subject taught in the class, active teacher, room and teacher clashes,
--     teaching periods only) is checked exactly as for an admin's own entry.
--
-- The teacher is always the logged-in user's own staff record (same as My
-- Leave): no operation takes a staff id from the browser.
--
-- Target DB: PostgreSQL. Safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS academic.timetable_requests (
    request_id                serial       PRIMARY KEY,
    tenant_id                 integer      NOT NULL,
    school_id                 integer      NOT NULL,
    academic_year_id          integer      NOT NULL,
    academic_class_section_id integer      NOT NULL,
    day_of_week               smallint     NOT NULL,
    period_seq                smallint     NOT NULL,
    subject_id                integer      NOT NULL,
    staff_id                  integer      NOT NULL,
    status                    varchar(10)  NOT NULL DEFAULT 'Pending',  -- Pending | Approved | Rejected | Cancelled
    note                      varchar(300),                              -- why it was rejected
    requested_by              integer      NOT NULL,
    requested_at              timestamptz  NOT NULL DEFAULT now(),
    decided_by                integer,
    decided_at                timestamptz
);

CREATE INDEX IF NOT EXISTS ix_timetable_requests_school
    ON academic.timetable_requests (tenant_id, school_id, status);

CREATE OR REPLACE PROCEDURE academic.sp_timetable_request_manage(
    IN    p_operation      varchar,
    IN    p_tenant_id      integer,
    IN    p_school_id      integer,
    IN    p_action_user_id integer,
    IN    p_section_id     integer  DEFAULT NULL,
    IN    p_day            smallint DEFAULT NULL,
    IN    p_period_seq     smallint DEFAULT NULL,
    IN    p_subject_id     integer  DEFAULT NULL,
    IN    p_request_id     integer  DEFAULT NULL,
    IN    p_reason         varchar  DEFAULT NULL,
    INOUT p_result         refcursor DEFAULT 'result_cursor'::refcursor
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_staff  integer;
    v_year   integer;
    v_class  integer;
    v_clash  text;
    r        academic.timetable_requests%ROWTYPE;
    c1 refcursor; c2 refcursor; c3 refcursor; c4 refcursor;
BEGIN
    IF p_tenant_id <= 1 OR p_school_id <= 0 THEN
        RAISE EXCEPTION 'Invalid school scope.';
    END IF;

    -- ── Teacher: ask for a period ───────────────────────────────────────────
    IF p_operation = 'Request' THEN
        SELECT st.staff_id INTO v_staff
        FROM core.staff st
        WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
          AND st.user_id = p_action_user_id
          AND NOT COALESCE(st.is_deleted, FALSE) AND COALESCE(st.is_active, TRUE)
          AND LOWER(COALESCE(st.staff_type, '')) = 'teaching'
        LIMIT 1;
        IF v_staff IS NULL THEN
            RAISE EXCEPTION 'Only teaching staff can request periods.';
        END IF;

        IF p_section_id IS NULL OR p_day IS NULL OR p_period_seq IS NULL OR p_subject_id IS NULL THEN
            RAISE EXCEPTION 'Pick a class, a subject and a period.';
        END IF;

        SELECT sec.academic_year_id, sec.academic_class_id INTO v_year, v_class
        FROM academic.academic_class_sections sec
        WHERE sec.academic_class_section_id = p_section_id
          AND sec.tenant_id = p_tenant_id AND sec.school_id = p_school_id
          AND NOT COALESCE(sec.is_deleted, FALSE);
        IF v_year IS NULL THEN
            RAISE EXCEPTION 'That section does not belong to this school.';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM academic.class_subjects cs
                       WHERE cs.tenant_id = p_tenant_id AND cs.school_id = p_school_id
                         AND cs.academic_year_id = v_year AND cs.academic_class_id = v_class
                         AND cs.subject_id = p_subject_id) THEN
            RAISE EXCEPTION 'That subject is not taught in this class.';
        END IF;

        -- Already teaching ANOTHER section in this slot (the same section is a change request).
        SELECT c.class_name || ' – ' || sec.section_name INTO v_clash
        FROM academic.timetable t
        JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = t.academic_class_section_id
        JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
        WHERE t.tenant_id = p_tenant_id AND t.school_id = p_school_id AND t.academic_year_id = v_year
          AND t.staff_id = v_staff AND t.day_of_week = p_day AND t.period_seq = p_period_seq
          AND t.academic_class_section_id <> p_section_id
        LIMIT 1;
        IF v_clash IS NOT NULL THEN
            RAISE EXCEPTION 'You already teach % in this period.', v_clash;
        END IF;

        IF EXISTS (SELECT 1 FROM academic.timetable_requests q
                   WHERE q.tenant_id = p_tenant_id AND q.school_id = p_school_id
                     AND q.staff_id = v_staff AND q.status = 'Pending'
                     AND q.day_of_week = p_day AND q.period_seq = p_period_seq) THEN
            RAISE EXCEPTION 'You already have a pending request for this period. Cancel it first.';
        END IF;

        INSERT INTO academic.timetable_requests
            (tenant_id, school_id, academic_year_id, academic_class_section_id, day_of_week, period_seq,
             subject_id, staff_id, requested_by)
        VALUES (p_tenant_id, p_school_id, v_year, p_section_id, p_day, p_period_seq,
                p_subject_id, v_staff, p_action_user_id);

        OPEN p_result FOR SELECT TRUE AS success, 'Request sent. It goes live once an admin approves it.' AS message;

    -- ── Teacher: cancel their own pending request ──────────────────────────
    ELSIF p_operation = 'Cancel' THEN
        UPDATE academic.timetable_requests q
        SET status = 'Cancelled', decided_by = p_action_user_id, decided_at = now()
        WHERE q.request_id = p_request_id AND q.status = 'Pending'
          AND q.tenant_id = p_tenant_id AND q.school_id = p_school_id
          AND q.staff_id IN (SELECT st.staff_id FROM core.staff st
                             WHERE st.tenant_id = p_tenant_id AND st.school_id = p_school_id
                               AND st.user_id = p_action_user_id);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Only your own pending request can be cancelled.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Request cancelled.' AS message;

    -- ── Teacher: my requests (Mine) / Admin: every pending request (Pending) ──
    ELSIF p_operation IN ('Mine', 'Pending') THEN
        OPEN p_result FOR
        SELECT q.request_id, q.status, q.note, q.day_of_week, q.period_seq,
               -- the period's name ("Period 6") from that day's bell schedule, else the default one;
               -- period_seq alone counts the assembly and breaks too
               (SELECT ps.label FROM academic.period_structure ps
                WHERE ps.tenant_id = q.tenant_id AND ps.school_id = q.school_id AND ps.seq = q.period_seq
                  AND (ps.day_of_week = q.day_of_week OR ps.day_of_week IS NULL)
                ORDER BY ps.day_of_week NULLS LAST LIMIT 1) AS period_label,
               to_char(q.requested_at, 'DD Mon YYYY, HH12:MI AM') AS requested_at,
               q.academic_class_section_id AS section_id,
               c.class_name || ' – ' || sec.section_name        AS section_label,
               s.subject_name, st.full_name AS teacher_name,
               -- what is live in that slot now, so the admin sees what approving replaces
               (SELECT ls.subject_name || COALESCE(' · ' || lst.full_name, '')
                FROM academic.timetable t
                JOIN academic.school_subjects ls ON ls.subject_id = t.subject_id
                LEFT JOIN core.staff lst ON lst.staff_id = t.staff_id
                WHERE t.tenant_id = q.tenant_id AND t.school_id = q.school_id
                  AND t.academic_year_id = q.academic_year_id
                  AND t.academic_class_section_id = q.academic_class_section_id
                  AND t.day_of_week = q.day_of_week AND t.period_seq = q.period_seq
                LIMIT 1) AS live_now
        FROM academic.timetable_requests q
        JOIN academic.academic_class_sections sec ON sec.academic_class_section_id = q.academic_class_section_id
        JOIN academic.academic_classes c ON c.academic_class_id = sec.academic_class_id
        JOIN academic.school_subjects s ON s.subject_id = q.subject_id
        JOIN core.staff st ON st.staff_id = q.staff_id
        WHERE q.tenant_id = p_tenant_id AND q.school_id = p_school_id
          AND (   (p_operation = 'Pending' AND q.status = 'Pending')
               OR (p_operation = 'Mine' AND st.user_id = p_action_user_id
                   AND q.status <> 'Cancelled' AND q.requested_at > now() - interval '60 days'))
        ORDER BY q.requested_at DESC;

    -- ── Admin: approve -> goes live through SaveCell ────────────────────────
    ELSIF p_operation = 'Approve' THEN
        SELECT * INTO r FROM academic.timetable_requests
        WHERE request_id = p_request_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND status = 'Pending'
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This request is no longer pending.';
        END IF;

        -- Every timetable rule is checked here; a clash raises and nothing changes.
        CALL academic.sp_school_admin_timetable_manage('SaveCell', p_tenant_id, p_school_id, p_action_user_id,
             r.academic_year_id, r.academic_class_section_id, r.day_of_week, r.period_seq,
             r.subject_id, r.staff_id, NULL, c1, c2, c3, c4);
        CLOSE c1; CLOSE c2; CLOSE c3; CLOSE c4;

        UPDATE academic.timetable_requests
        SET status = 'Approved', decided_by = p_action_user_id, decided_at = now()
        WHERE request_id = r.request_id;

        -- Other teachers' pending requests for the same section + period cannot also win.
        UPDATE academic.timetable_requests
        SET status = 'Rejected', note = 'Another request for this period was approved.',
            decided_by = p_action_user_id, decided_at = now()
        WHERE tenant_id = p_tenant_id AND school_id = p_school_id AND status = 'Pending'
          AND academic_class_section_id = r.academic_class_section_id
          AND day_of_week = r.day_of_week AND period_seq = r.period_seq;

        OPEN p_result FOR SELECT TRUE AS success, 'Approved. The period is live on the timetable.' AS message;

    -- ── Admin: reject with a reason ────────────────────────────────────────
    ELSIF p_operation = 'Reject' THEN
        IF NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN
            RAISE EXCEPTION 'Give a reason so the teacher knows why.';
        END IF;
        UPDATE academic.timetable_requests
        SET status = 'Rejected', note = LEFT(TRIM(p_reason), 300),
            decided_by = p_action_user_id, decided_at = now()
        WHERE request_id = p_request_id AND tenant_id = p_tenant_id AND school_id = p_school_id
          AND status = 'Pending';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'This request is no longer pending.';
        END IF;
        OPEN p_result FOR SELECT TRUE AS success, 'Request rejected.' AS message;

    ELSE
        RAISE EXCEPTION 'Invalid operation %', p_operation;
    END IF;
END;
$procedure$;
