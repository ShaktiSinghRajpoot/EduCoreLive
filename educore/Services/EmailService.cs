using System.Net;
using System.Net.Http.Json;
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

        // One shared client for the HTTPS provider (the service is a singleton).
        private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(20) };

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

            if (string.Equals(_settings.Provider, "Brevo", StringComparison.OrdinalIgnoreCase))
                return await SendViaBrevoAsync(toEmail, toName, subject, htmlBody, ct);

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

        // Brevo transactional email over HTTPS (https://developers.brevo.com/reference/sendtransacemail).
        // Used in production because Railway blocks outbound SMTP below its Pro plan.
        // The sender address must be verified in the Brevo account (a single sender, or
        // the whole domain once its DNS records are added).
        private async Task<bool> SendViaBrevoAsync(string toEmail, string toName, string subject, string htmlBody, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(_settings.ApiKey) || string.IsNullOrWhiteSpace(_settings.FromAddress))
            {
                _logger.LogError("Brevo email is misconfigured (ApiKey/FromAddress missing). Cannot send '{Subject}' to {To}.", subject, toEmail);
                return false;
            }

            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.brevo.com/v3/smtp/email");
                request.Headers.Add("api-key", _settings.ApiKey);
                request.Headers.Add("accept", "application/json");
                request.Content = JsonContent.Create(new
                {
                    sender = new { name = _settings.FromName, email = _settings.FromAddress },
                    to = new[] { new { email = toEmail, name = string.IsNullOrWhiteSpace(toName) ? toEmail : toName } },
                    subject,
                    htmlContent = htmlBody
                });

                using var response = await _http.SendAsync(request, ct);
                if (response.IsSuccessStatusCode)
                {
                    _logger.LogInformation("Sent email '{Subject}' to {To} via Brevo.", subject, toEmail);
                    return true;
                }

                // Brevo explains the refusal in the body (bad key, unverified sender, quota...).
                var body = await response.Content.ReadAsStringAsync(ct);
                _logger.LogError("Brevo refused email '{Subject}' to {To}: {Status} {Body}", subject, toEmail, (int)response.StatusCode, body);
                return false;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Failed to send email '{Subject}' to {To} via Brevo.", subject, toEmail);
                return false;
            }
        }
    }
}
