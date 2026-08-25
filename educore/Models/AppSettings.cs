namespace educore.Models
{
    // General app settings, bound from the "AppSettings" config section and injected
    // as IOptions<AppSettings> (same pattern as EmailSettings / SmsSettings).
    public class AppSettings
    {
        // Purpose string handed to IDataProtectionProvider.CreateProtector. It is a label,
        // not a key — but it MUST stay fixed: change it and every value protected with the
        // old purpose can no longer be unprotected.
        public string ProtectorValue { get; set; } = string.Empty;
    }
}
