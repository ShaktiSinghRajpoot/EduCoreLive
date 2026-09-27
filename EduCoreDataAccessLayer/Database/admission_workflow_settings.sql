-- ============================================================================
-- Admission Workflow Settings
-- Per-school configuration that drives the Enquiry -> Admission journey.
-- Lets one SaaS instance serve both "registration" schools and
-- "direct admission" schools by toggling the optional Registration stage.
--
-- Target DB: PostgreSQL (educore)
-- Safe to re-run (idempotent).
-- ============================================================================

-- ── Table ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.school_admission_workflow_settings
(
    school_admission_workflow_id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id                               integer NOT NULL,
    school_id                               integer NOT NULL,

    enable_registration                     boolean       NOT NULL DEFAULT FALSE,
    registration_required_before_admission  boolean       NOT NULL DEFAULT FALSE,
    enable_registration_fee                 boolean       NOT NULL DEFAULT FALSE,
    registration_fee_amount                 numeric(12,2) NOT NULL DEFAULT 0,
    auto_generate_registration_number       boolean       NOT NULL DEFAULT TRUE,
    registration_number_prefix              varchar(20)   NOT NULL DEFAULT 'REG-',

    created_by                              integer   NOT NULL,
    created_at                              timestamp without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by                              integer,
    updated_at                              timestamp without time zone,
    deleted_by                              integer,
    deleted_at                              timestamp without time zone,
    is_deleted                              boolean   NOT NULL DEFAULT FALSE,
    is_active                               boolean   NOT NULL DEFAULT TRUE,

    CONSTRAINT chk_school_admission_workflow_scope CHECK ((tenant_id > 1) AND (school_id > 0)),
    CONSTRAINT uq_school_admission_workflow UNIQUE (tenant_id, school_id)
);

-- ── The procedure is not defined here any more ─────────────────────────────
--  core.sp_school_admin_admission_workflow_manage used to be re-created at this
--  point, with whatever parameters this migration added. It is now owned by ONE
--  file, **fee_charge_from_per_year.sql**, and only that file defines it.
--
--  Eight files used to define this procedure. Each one was correct on the day it
--  was written and every one of them says "safe to re-run", so running an older
--  one reverted everything the newer ones had added -- silently, with no error.
--  That is not hypothetical: fee_collection_point.sql was still holding a stale
--  copy of the fee head procedure hours after it had been rewritten, and would
--  have undone the whole of it.
--
--  What this file still owns: the core.school_admission_workflow_settings table itself.
