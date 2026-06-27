namespace educore.Services
{
    public interface IEmailService
    {
        /// <summary>
        /// Sends an HTML email. Returns true on success, false if email is disabled,
        /// misconfigured, or the send failed. Never throws — callers can branch on the
        /// result (e.g. fall back to showing credentials on screen).
        /// </summary>
        Task<bool> SendAsync(string toEmail, string toName, string subject, string htmlBody, CancellationToken ct = default);
    }
}
