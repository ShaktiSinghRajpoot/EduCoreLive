using educore.Services;

namespace educore.Models
{
    /// <summary>
    /// Backs Views/Account/SchoolUnavailable.cshtml — the page shown when sign-in is
    /// refused because of the school's status rather than the credentials.
    /// </summary>
    public class SchoolUnavailableViewModel
    {
        /// <summary>ACTIVE / INACTIVE / SUSPENDED / CLOSED / PENDING, or null on a direct visit.</summary>
        public string? StatusCode { get; set; }

        /// <summary>Wording from config.school_statuses.login_message.</summary>
        public string? Message { get; set; }

        public SupportSettings Support { get; set; } = new();

        /// <summary>Heading per status. Generic when the page is opened directly.</summary>
        public string Heading => StatusCode switch
        {
            "SUSPENDED" => "Access suspended",
            "INACTIVE" => "School inactive",
            "CLOSED" => "School closed",
            "PENDING" => "Not activated yet",
            _ => "School unavailable"
        };

        /// <summary>
        /// Whether this looks recoverable, which decides the closing line. Closed is
        /// terminal; the rest are usually a billing or setup step away from being fixed.
        /// </summary>
        public bool IsTerminal => StatusCode == "CLOSED";

        public string Body => string.IsNullOrWhiteSpace(Message)
            ? "This school is not currently active, so sign-in is unavailable."
            : Message!;

        /// <summary>Icon differs so the page reads at a glance.</summary>
        public string Icon => StatusCode switch
        {
            "SUSPENDED" => "bx-pause-circle",
            "CLOSED" => "bx-lock-alt",
            "PENDING" => "bx-time-five",
            _ => "bx-info-circle"
        };
    }
}
