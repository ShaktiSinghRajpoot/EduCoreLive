using System.Net;
using System.Net.Mail;
using Microsoft.Extensions.Options;

namespace educore.Services
{
    /// <summary>
    /// Thin SMTP sender over System.Net.Mail (no external package). Stateless over the
    /// bound <see cref="EmailSettings"/>, so it is registered as a singleton.
    /// </summary>
    public class EmailService : IEmailService
    {
        private readonly EmailSettings _settings;
        private readonly ILogger<EmailService> _logger;

        public EmailService(IOptions<EmailSettings> options, ILogger<EmailService> logger)
        {
            _settings = options.Value;
            _logger = logger;
        }

        public async Task<bool> SendAsync(string toEmail, string toName, string subject, string htmlBody, CancellationToken ct = default)
        {
            if (!_settings.Enabled)
            {
                _logger.LogWarning("Email is disabled (Email:Enabled=false). Skipped '{Subject}' to {To}.", subject, toEmail);
                return false;
            }

            if (string.IsNullOrWhiteSpace(_settings.Host) || string.IsNullOrWhiteSpace(_settings.FromAddress))
            {
                _logger.LogError("Email is misconfigured (Host/FromAddress missing). Cannot send '{Subject}' to {To}.", subject, toEmail);
                return false;
            }

            try
            {
                using var message = new MailMessage
                {
                    From = new MailAddress(_settings.FromAddress, _settings.FromName),
                    Subject = subject,
                    Body = htmlBody,
                    IsBodyHtml = true
                };
                message.To.Add(new MailAddress(toEmail, string.IsNullOrWhiteSpace(toName) ? toEmail : toName));

                using var client = new SmtpClient(_settings.Host, _settings.Port)
                {
                    EnableSsl = _settings.UseSsl,
                    DeliveryMethod = SmtpDeliveryMethod.Network
                };

                if (!string.IsNullOrWhiteSpace(_settings.Username))
                    client.Credentials = new NetworkCredential(_settings.Username, _settings.Password);

                await client.SendMailAsync(message, ct);

                _logger.LogInformation("Sent email '{Subject}' to {To}.", subject, toEmail);
                return true;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to send email '{Subject}' to {To}.", subject, toEmail);
                return false;
            }
        }
    }
}
