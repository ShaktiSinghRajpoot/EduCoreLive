namespace educore.Services.Notifications
{
    /// <summary>Channels a notification can go out on. [Flags] so a message can target several at once.</summary>
    [Flags]
    public enum NotificationChannels
    {
        None     = 0,
        Email    = 1,
        Sms      = 2,
        WhatsApp = 4,
        All      = Email | Sms | WhatsApp
    }

    /// <summary>
    /// One notification with per-channel content: <see cref="HtmlBody"/>/<see cref="Subject"/> for email,
    /// <see cref="PlainText"/> for SMS/WhatsApp. Each channel ignores what it can't use.
    /// </summary>
    public class NotificationMessage
    {
        public string? ToEmail { get; set; }
        public string? ToPhone { get; set; }
        public string? ToName { get; set; }

        public string Subject { get; set; } = string.Empty;    // email
        public string HtmlBody { get; set; } = string.Empty;   // email
        public string PlainText { get; set; } = string.Empty;  // sms / whatsapp

        public NotificationChannels Channels { get; set; } = NotificationChannels.All;
    }
}
