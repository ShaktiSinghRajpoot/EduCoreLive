using Microsoft.Extensions.Options;

namespace educore.Services.Notifications
{
    /// <summary>
    /// WhatsApp channel. Like <see cref="SmsChannel"/>, this LOGS the message until a provider is
    /// wired (WhatsApp needs a Business API account + Meta-approved templates). Implement the send
    /// in <see cref="SendViaProviderAsync"/> and set Notifications:WhatsApp:Enabled = true.
    /// </summary>
    public class WhatsAppChannel : INotificationChannel
    {
        private readonly WhatsAppSettings _settings;
        private readonly ILogger<WhatsAppChannel> _logger;

        public WhatsAppChannel(IOptions<WhatsAppSettings> options, ILogger<WhatsAppChannel> logger)
        {
            _settings = options.Value;
            _logger = logger;
        }

        public NotificationChannels Channel => NotificationChannels.WhatsApp;

        public Task<bool> SendAsync(NotificationMessage message, CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(message.ToPhone))
                return Task.FromResult(false);

            if (!_settings.Enabled)
            {
                _logger.LogWarning("[WhatsApp disabled] would send to {Phone}: {Text}", message.ToPhone, message.PlainText);
                return Task.FromResult(false);
            }

            return SendViaProviderAsync(message, ct);
        }

        // TODO: implement the real provider call (e.g. Meta Cloud API template message) here.
        private Task<bool> SendViaProviderAsync(NotificationMessage message, CancellationToken ct)
        {
            _logger.LogWarning("[WhatsApp provider '{Provider}' not implemented] to {Phone}: {Text}",
                _settings.Provider, message.ToPhone, message.PlainText);
            return Task.FromResult(false);
        }
    }
}
