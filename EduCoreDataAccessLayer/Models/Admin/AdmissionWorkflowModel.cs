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

        /// <summary>When true, a registration fee can be configured and collected.</summary>
        public bool EnableRegistrationFee { get; set; }

        /// <summary>Registration fee value (used only when <see cref="EnableRegistrationFee"/> is true).</summary>
        public decimal RegistrationFeeAmount { get; set; }

        /// <summary>When true, registration numbers are auto-generated using the prefix below.</summary>
        public bool AutoGenerateRegistrationNumber { get; set; } = true;

        /// <summary>Prefix for auto-generated registration numbers, e.g. "REG-2026-".</summary>
        public string RegistrationNumberPrefix { get; set; } = "REG-";

        // ── Admission ───────────────────────────────────────────────────────

        /// <summary>When true, the admission form can collect fee on the spot and issue a receipt.</summary>
        public bool CollectFeeAtAdmission { get; set; }

        /// <summary>When true, a one-time security deposit is added to the admission's due-now charges.</summary>
        public bool EnableSecurityFee { get; set; }

        /// <summary>Security deposit value (used only when <see cref="EnableSecurityFee"/> is true).</summary>
        public decimal SecurityFeeAmount { get; set; }
    }
}
