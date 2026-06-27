namespace educore.Services.Notifications
{
    /// <summary>One delivery channel (email, SMS, WhatsApp). Implementations never throw — they
    /// return false on disabled/misconfigured/failed so the fan-out can continue to other channels.</summary>
    public interface INotificationChannel
    {
        /// <summary>The single channel flag this adapter handles.</summary>
        NotificationChannels Channel { get; }

        Task<bool> SendAsync(NotificationMessage message, CancellationToken ct = default);
    }
}
