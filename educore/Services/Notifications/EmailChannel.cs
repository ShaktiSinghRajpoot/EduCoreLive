namespace educore.Services.Notifications
{
    /// <summary>Email channel — delegates to the existing <see cref="IEmailService"/> (SMTP).</summary>
    public class EmailChannel : INotificationChannel
    {
        private readonly IEmailService _email;

        public EmailChannel(IEmailService email) => _email = email;

        public NotificationChannels Channel => NotificationChannels.Email;

        public Task<bool> SendAsync(NotificationMessage message, CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(message.ToEmail))
                return Task.FromResult(false);

            return _email.SendAsync(
                message.ToEmail!,
                string.IsNullOrWhiteSpace(message.ToName) ? message.ToEmail! : message.ToName!,
                message.Subject,
                message.HtmlBody,
                ct);
        }
    }
}
