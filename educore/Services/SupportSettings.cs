namespace educore.Services
{
    /// <summary>
    /// Platform support contact details, bound from the "Support" configuration section.
    ///
    /// Shown on the public website (Views/Site/Index) and on Account/SchoolUnavailable — the page a user lands on when their
    /// credentials are correct but the school's status (Inactive / Suspended /
    /// Closed / Pending) blocks sign-in. Being told "your school is suspended" with
    /// no way to reach anyone is a dead end, so the page carries real contacts.
    ///
    /// These are public-facing details, not secrets, so committing them in
    /// appsettings.json is fine. Override per environment with Support__* env vars.
    /// </summary>
    public class SupportSettings
    {
        /// <summary>The person to ask for (the public website's contact block).</summary>
        public string Name { get; set; } = string.Empty;

        public string Email { get; set; } = string.Empty;
        public string Phone { get; set; } = string.Empty;

        /// <summary>Country code + number, no + or spaces (e.g. 919876543210), for wa.me links.</summary>
        public string WhatsApp { get; set; } = string.Empty;

        /// <summary>e.g. "Mon–Sat, 9:00 AM – 6:00 PM IST". Shown under the phone number.</summary>
        public string Hours { get; set; } = string.Empty;

        /// <summary>Optional website/helpdesk URL. Hidden when blank.</summary>
        public string Website { get; set; } = string.Empty;

        /// <summary>
        /// The public website's address without a trailing slash, for the canonical link
        /// and sitemap.xml. It is Website, so Google always gets smartschoolwala.com even
        /// when the page is opened on the Railway address; when Website is blank, the
        /// address the request came in on.
        /// </summary>
        public string PublicUrl(HttpRequest request) =>
            string.IsNullOrWhiteSpace(Website)
                ? $"{request.Scheme}://{request.Host}"
                : Website.TrimEnd('/');

        /// <summary>Falls back so the page never renders an empty contact block.</summary>
        public bool HasAnyContact =>
            !string.IsNullOrWhiteSpace(Email) ||
            !string.IsNullOrWhiteSpace(Phone) ||
            !string.IsNullOrWhiteSpace(Website);
    }
}
