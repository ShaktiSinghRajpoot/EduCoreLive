namespace educore.Models
{
    /// <summary>
    /// The modules the Super Admin gave one school. A module not given is hidden
    /// everywhere in that school; the School Admin cannot switch it on.
    /// </summary>
    public class SchoolModulesModel
    {
        public int    SchoolId       { get; set; }
        public string SchoolName     { get; set; } = string.Empty;
        public bool   AllowTransport { get; set; } = true;
        public bool   AllowExams     { get; set; } = true;
        public bool   AllowInventory { get; set; } = true;
        public bool   AllowPayroll   { get; set; } = true;

        /// <summary>WhatsApp messages to parents from the platform's account (off by default:
        /// every message costs money). Saved in core.school_messaging.</summary>
        public bool   AllowWhatsApp  { get; set; }
        public int    WhatsAppSentThisMonth { get; set; }
    }

    /// <summary>Who to sign in as when the Super Admin opens a school.</summary>
    public class LoginAsTarget
    {
        public int UserId   { get; set; }
        public int TenantId { get; set; }
        public int SchoolId { get; set; }
        public int LogId    { get; set; }
    }
}
