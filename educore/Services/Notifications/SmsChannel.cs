using Microsoft.Extensions.Options;

namespace educore.Services.Notifications
{
    /// <summary>
    /// SMS channel. No provider is wired yet, so this currently LOGS the message instead of sending.
    /// That keeps the OTP/temp-password flows fully testable for free (read the code in the app log).
    /// When you adopt a provider (MSG91/Twilio/…), implement the send in <see cref="SendViaProviderAsync"/>
    /// and set Notifications:Sms:Enabled = true.
    /// </summary>
    public class SmsChannel : INotificationChannel
    {
        private readonly SmsSettings _settings;
        private readonly ILogger<SmsChannel> _logger;

        public SmsChannel(IOptions<SmsSettings> options, ILogger<SmsChannel> logger)
        {
            _settings = options.Value;
            _logger = logger;
        }

        public NotificationChannels Channel => NotificationChannels.Sms;

        public Task<bool> SendAsync(NotificationMessage message, CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(message.ToPhone))
                return Task.FromResult(false);

            if (!_settings.Enabled)
            {
                // Dev / no-provider mode: surface the text (e.g. the OTP) so it can be used without paying.
                _logger.LogWarning("[SMS disabled] would send to {Phone}: {Text}", message.ToPhone, message.PlainText);
                return Task.FromResult(false);
            }

            return SendViaProviderAsync(message, ct);
        }

        // TODO: implement the real provider call (e.g. MSG91/Twilio HTTP API) here.
        private Task<bool> SendViaProviderAsync(NotificationMessage message, CancellationToken ct)
        {
            _logger.LogWarning("[SMS provider '{Provider}' not implemented] to {Phone}: {Text}",
                _settings.Provider, message.ToPhone, message.PlainText);
            return Task.FromResult(false);
        }
    }
}
