namespace educore.Services.Notifications
{
    /// <summary>
    /// SMS provider settings (config section "Notifications:Sms"). When <see cref="Enabled"/> is
    /// false (the default) the channel just logs the message — handy in dev to read OTPs for free,
    /// with no provider account. The provider fields are placeholders for when a real adapter is wired.
    /// </summary>
    public class SmsSettings
    {
        public bool Enabled { get; set; }
        public string Provider { get; set; } = string.Empty;   // e.g. "MSG91", "Twilio"
        public string ApiKey { get; set; } = string.Empty;
        public string SenderId { get; set; } = string.Empty;
    }

    /// <summary>
    /// WhatsApp settings (config section "Notifications:WhatsApp"): ONE platform account, the
    /// WhatsApp Business (Meta Cloud API) number SmartSchoolWala sends from. Set them as Railway
    /// environment variables, e.g. Notifications__WhatsApp__Enabled = true. While Enabled is false
    /// every message is built, shown and recorded as "Test", and nothing is sent.
    ///
    /// A school-to-parent message must use a template Meta has approved. Create these three in
    /// WhatsApp Manager (category Utility) with the body text below, and put their names here:
    ///   AbsentTemplate  "Dear Parent, {{1}} ({{2}}) was absent on {{3}}. Please inform the school if this is unexpected. - {{4}}"
    ///   FeeTemplate     "Dear Parent, a fee of Rs {{1}} for {{2}} is due. Please pay at the earliest; ignore if already paid. - {{3}}"
    ///   NoticeTemplate  "{{1}}: {{2}} - {{3}}"   (school, notice title, notice text)
    /// </summary>
    public class WhatsAppSettings
    {
        public bool Enabled { get; set; }
        public string Provider { get; set; } = "MetaCloud";
        public string ApiKey { get; set; } = string.Empty;        // Meta: the permanent access token
        public string FromNumber { get; set; } = string.Empty;    // the business number, for display
        public string PhoneNumberId { get; set; } = string.Empty; // Meta: the "Phone number ID" of that number
        public string ApiVersion { get; set; } = "v21.0";
        public string Language { get; set; } = "en";              // the templates' language code (en, hi, en_US ...)
        public string AbsentTemplate { get; set; } = "absent_alert";
        public string FeeTemplate { get; set; } = "fee_reminder";
        public string NoticeTemplate { get; set; } = "school_notice";
    }
}
