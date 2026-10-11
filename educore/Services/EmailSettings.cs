namespace educore.Services
{
    /// <summary>
    /// SMTP settings bound from the "Email" configuration section.
    /// Non-secret defaults live in appsettings.json; real credentials belong in
    /// appsettings.Development.json (git-ignored) or the Email__* environment variables.
    /// </summary>
    public class EmailSettings
    {
        /// <summary>Master switch. When false, the app logs and skips sending (no SMTP call).</summary>
        public bool Enabled { get; set; }

        public string Host { get; set; } = string.Empty;
        public int Port { get; set; } = 587;
        public bool UseSsl { get; set; } = true;

        public string Username { get; set; } = string.Empty;
        public string Password { get; set; } = string.Empty;

        public string FromAddress { get; set; } = string.Empty;
        public string FromName { get; set; } = "SmartSchoolWala.com";

        /// <summary>
        /// "Smtp" (default) or "Brevo". Railway blocks outbound SMTP below its Pro plan,
        /// so production sends through Brevo's HTTPS API instead; local dev keeps SMTP.
        /// </summary>
        public string Provider { get; set; } = "Smtp";

        /// <summary>API key for the HTTPS provider (Brevo). Set as Email__ApiKey; never commit it.</summary>
        public string ApiKey { get; set; } = string.Empty;
    }
}
