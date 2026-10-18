using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;

namespace educore.Services.Notifications
{
    /// <summary>
    /// WhatsApp alerts to parents, one place for every page: absent alert, fee reminder, notice.
    /// It sends the approved template (or, while the platform account is not connected, sends
    /// nothing and says "Test"), and writes every message to core.message_log either way.
    /// The pages check <see cref="IsOnAsync"/> first: the Super Admin switches WhatsApp per school.
    /// </summary>
    public class SchoolMessenger
    {
        public const string Absent = "Absent";
        public const string FeeDue = "FeeDue";
        public const string Notice = "Notice";

        private readonly WhatsAppChannel _whatsApp;
        private readonly IMessageLogService _log;

        public SchoolMessenger(WhatsAppChannel whatsApp, IMessageLogService log)
        {
            _whatsApp = whatsApp;
            _log = log;
        }

        /// <summary>True while the platform's WhatsApp account is not connected: messages are recorded, not sent.</summary>
        public bool TestMode => !_whatsApp.Settings.Enabled
                                || string.IsNullOrWhiteSpace(_whatsApp.Settings.ApiKey)
                                || string.IsNullOrWhiteSpace(_whatsApp.Settings.PhoneNumberId);

        /// <summary>Has the Super Admin switched WhatsApp on for this school?</summary>
        public Task<bool> IsOnAsync(int tenantId, int schoolId) => _log.IsWhatsAppOnAsync(tenantId, schoolId);

        /// <summary>
        /// Sends one alert to one parent and records it. Returns the status written to the log:
        /// Sent | Failed | Test | NoPhone.
        /// </summary>
        public async Task<string> SendAsync(int tenantId, int schoolId, int userId, string alertType,
                                            int? studentId, string? toName, string? phone, IList<string> values)
        {
            string template = TemplateFor(alertType);
            var entry = new MessageLogEntry
            {
                AlertType   = alertType,
                StudentId   = studentId,
                ToName      = toName,
                ToPhone     = phone,
                MessageText = Preview(alertType, values),
                Template    = template
            };

            if (WhatsAppChannel.ToWhatsAppNumber(phone) == null)
            {
                entry.Status = "NoPhone";
                entry.Error  = "No valid mobile number on record.";
            }
            else
            {
                var r = await _whatsApp.SendTemplateAsync(phone!, template, values);
                entry.Status      = r.Sent ? "Sent" : (r.TestMode ? "Test" : "Failed");
                entry.ProviderRef = r.ProviderRef;
                entry.Error       = r.Error;
            }

            try { await _log.AddAsync(entry, tenantId, schoolId, userId); }
            catch { /* the message went (or not) either way; a missing log row is not worth failing the page */ }
            return entry.Status;
        }

        private string TemplateFor(string alertType) => alertType switch
        {
            Absent => _whatsApp.Settings.AbsentTemplate,
            FeeDue => _whatsApp.Settings.FeeTemplate,
            _      => _whatsApp.Settings.NoticeTemplate
        };

        /// <summary>What the parent reads: the template's body (see WhatsAppSettings) filled in.</summary>
        public static string Preview(string alertType, IList<string> v)
        {
            string V(int i) => i < v.Count ? v[i] : "";
            return alertType switch
            {
                Absent => $"Dear Parent, {V(0)} ({V(1)}) was absent on {V(2)}. Please inform the school if this is unexpected. - {V(3)}",
                FeeDue => $"Dear Parent, a fee of Rs {V(0)} for {V(1)} is due. Please pay at the earliest; ignore if already paid. - {V(2)}",
                _      => $"{V(0)}: {V(1)} - {V(2)}"
            };
        }
    }
}
