namespace EduCoreDataAccessLayer.Models.Admin
{
    /// <summary>
    /// School-level configuration that drives the Enquiry → Admission journey.
    /// Lets a single SaaS instance serve both "registration" schools and
    /// "direct admission" schools by toggling the optional Registration stage.
    /// </summary>
    public class AdmissionWorkflowModel
    {
        public string Operation { get; set; } = "SaveAdmissionWorkflow";

        public int TenantId { get; set; }
        public int SchoolId { get; set; }

        // ── Registration stage ──────────────────────────────────────────────

        /// <summary>Master switch: does this school use a Registration stage at all?</summary>
        public bool EnableRegistration { get; set; }

        /// <summary>When true, an enquiry cannot be converted to admission until registered.</summary>
        public bool RegistrationRequiredBeforeAdmission { get; set; }

        /// <summary>
        /// When true, this school collects a registration fee at the registration step.
        /// The amount is master data — defined as a Fee Head with Collection Point =
        /// "Registration" in School Settings → Fee Head, not stored here.
        /// </summary>
        public bool EnableRegistrationFee { get; set; }

        /// <summary>When true, registration numbers are auto-generated using the prefix below.</summary>
        public bool AutoGenerateRegistrationNumber { get; set; } = true;

        /// <summary>Prefix for auto-generated registration numbers, e.g. "REG-2026-".</summary>
        public string RegistrationNumberPrefix { get; set; } = "REG-";

        // ── Admission ───────────────────────────────────────────────────────

        /// <summary>When true, the admission form can collect fee on the spot and issue a receipt.</summary>
        public bool CollectFeeAtAdmission { get; set; }

        /// <summary>
        /// When true, this school charges a one-time security deposit at admission.
        /// The amount is master data — defined as a refundable Fee Head with Collection
        /// Point = "Admission" in School Settings → Fee Head, not stored here.
        /// </summary>
        public bool EnableSecurityFee { get; set; }

        // ── Transport module ────────────────────────────────────────────────

        /// <summary>
        /// Master switch for the Transport module. When false, the school sees no
        /// transport UI at all — the Transport side-menu (Routes / Vehicles / Assign)
        /// and the "School Transport" panel on the admission form are hidden. Defaults
        /// to true so schools that already use buses are unaffected. Per-stop bus fares
        /// live in the Transport module, not here.
        /// </summary>
        public bool EnableTransport { get; set; } = true;
    }
}
