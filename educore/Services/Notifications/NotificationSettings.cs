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

    /// <summary>WhatsApp provider settings (config section "Notifications:WhatsApp"). See <see cref="SmsSettings"/>.</summary>
    public class WhatsAppSettings
    {
        public bool Enabled { get; set; }
        public string Provider { get; set; } = string.Empty;   // e.g. "MetaCloud", "Gupshup"
        public string ApiKey { get; set; } = string.Empty;
        public string FromNumber { get; set; } = string.Empty;
    }
}
