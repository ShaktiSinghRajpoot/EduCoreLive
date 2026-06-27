namespace educore.Services.Notifications
{
    public interface INotificationService
    {
        /// <summary>
        /// Sends the message on every requested channel that is registered and able to deliver.
        /// Returns the set of channels that actually delivered (use it to decide on-screen fallbacks).
        /// Never throws — a failing channel is logged and skipped.
        /// </summary>
        Task<NotificationChannels> SendAsync(NotificationMessage message, CancellationToken ct = default);
    }

    /// <summary>Fans a <see cref="NotificationMessage"/> out across the registered channel adapters.</summary>
    public class NotificationService : INotificationService
    {
        private readonly IEnumerable<INotificationChannel> _channels;
        private readonly ILogger<NotificationService> _logger;

        public NotificationService(IEnumerable<INotificationChannel> channels, ILogger<NotificationService> logger)
        {
            _channels = channels;
            _logger = logger;
        }

        public async Task<NotificationChannels> SendAsync(NotificationMessage message, CancellationToken ct = default)
        {
            var delivered = NotificationChannels.None;

            foreach (var channel in _channels)
            {
                if (!message.Channels.HasFlag(channel.Channel))
                    continue;

                try
                {
                    if (await channel.SendAsync(message, ct))
                        delivered |= channel.Channel;
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Notification channel {Channel} threw while sending '{Subject}'.",
                        channel.Channel, message.Subject);
                }
            }

            return delivered;
        }
    }
}
