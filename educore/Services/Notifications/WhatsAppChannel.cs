using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace educore.Services.Notifications
{
    /// <summary>What happened to one WhatsApp message.</summary>
    public class WhatsAppResult
    {
        public bool    Sent        { get; set; }
        public bool    TestMode    { get; set; }   // the platform account is not connected: nothing was sent
        public string? ProviderRef { get; set; }   // Meta's message id
        public string? Error       { get; set; }
    }

    /// <summary>
    /// WhatsApp channel: Meta Cloud API template messages from the platform's one business number
    /// (see <see cref="WhatsAppSettings"/>). While Notifications:WhatsApp:Enabled is false it
    /// sends nothing and says so (TestMode), so every screen can be used before the account exists.
    /// </summary>
    public class WhatsAppChannel : INotificationChannel
    {
        private readonly WhatsAppSettings _settings;
        private readonly IHttpClientFactory _http;
        private readonly ILogger<WhatsAppChannel> _logger;

        public WhatsAppChannel(IOptions<WhatsAppSettings> options, IHttpClientFactory http, ILogger<WhatsAppChannel> logger)
        {
            _settings = options.Value;
            _http = http;
            _logger = logger;
        }

        public NotificationChannels Channel => NotificationChannels.WhatsApp;
        public WhatsAppSettings Settings => _settings;

        // Free text cannot go to a parent who has not written first (WhatsApp's rule), so the
        // generic fan-out does not send on WhatsApp: the pages use SendTemplateAsync instead.
        public Task<bool> SendAsync(NotificationMessage message, CancellationToken ct = default) => Task.FromResult(false);

        /// <summary>
        /// Sends one approved template to an Indian mobile number with its {{1}}, {{2}} ... values.
        /// Never throws.
        /// </summary>
        public async Task<WhatsAppResult> SendTemplateAsync(string phone, string template, IList<string> values, CancellationToken ct = default)
        {
            var to = ToWhatsAppNumber(phone);
            if (to == null) return new WhatsAppResult { Error = "No valid mobile number." };

            if (!_settings.Enabled || string.IsNullOrWhiteSpace(_settings.ApiKey) || string.IsNullOrWhiteSpace(_settings.PhoneNumberId))
                return new WhatsAppResult { TestMode = true };

            try
            {
                var body = new
                {
                    messaging_product = "whatsapp",
                    to,
                    type = "template",
                    template = new
                    {
                        name = template,
                        language = new { code = _settings.Language },
                        components = new object[]
                        {
                            new
                            {
                                type = "body",
                                parameters = values.Select(v => new { type = "text", text = CleanValue(v) }).ToArray()
                            }
                        }
                    }
                };

                var client = _http.CreateClient("whatsapp");
                using var req = new HttpRequestMessage(HttpMethod.Post,
                    $"https://graph.facebook.com/{_settings.ApiVersion}/{_settings.PhoneNumberId}/messages");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _settings.ApiKey);
                req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

                using var res = await client.SendAsync(req, ct);
                var text = await res.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(text) ? "{}" : text);

                if (res.IsSuccessStatusCode
                    && doc.RootElement.TryGetProperty("messages", out var msgs) && msgs.GetArrayLength() > 0)
                {
                    return new WhatsAppResult { Sent = true, ProviderRef = msgs[0].GetProperty("id").GetString() };
                }

                var error = doc.RootElement.TryGetProperty("error", out var err) && err.TryGetProperty("message", out var em)
                    ? em.GetString() : $"WhatsApp answered {(int)res.StatusCode}.";
                _logger.LogWarning("WhatsApp template {Template} to {Phone} refused: {Error}", template, to, error);
                return new WhatsAppResult { Error = error };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "WhatsApp template {Template} to {Phone} failed.", template, to);
                return new WhatsAppResult { Error = "Could not reach WhatsApp." };
            }
        }

        /// <summary>"98391 01237", "+91-9839101237", "09839101237" -> "919839101237"; null when it is not a mobile number.</summary>
        public static string? ToWhatsAppNumber(string? phone)
        {
            var digits = new string((phone ?? "").Where(char.IsDigit).ToArray());
            if (digits.Length == 12 && digits.StartsWith("91")) digits = digits.Substring(2);
            if (digits.Length == 11 && digits.StartsWith("0")) digits = digits.Substring(1);
            return digits.Length == 10 && "6789".Contains(digits[0]) ? "91" + digits : null;
        }

        // A template value may not hold new lines, tabs or more than four spaces in a row.
        private static string CleanValue(string? v)
        {
            var s = (v ?? "").Replace("\r", " ").Replace("\n", " ").Replace("\t", " ").Trim();
            while (s.Contains("     ")) s = s.Replace("     ", "    ");
            return s.Length > 1000 ? s.Substring(0, 997) + "..." : (s == "" ? "-" : s);
        }
    }
}
