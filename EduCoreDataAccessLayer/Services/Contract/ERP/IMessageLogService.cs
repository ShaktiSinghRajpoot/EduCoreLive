using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>WhatsApp per school and the record of every message (messaging.sql).</summary>
    public interface IMessageLogService
    {
        /// <summary>Has the Super Admin switched WhatsApp on for this school?</summary>
        Task<bool> IsWhatsAppOnAsync(int tenantId, int schoolId);

        Task AddAsync(MessageLogEntry entry, int tenantId, int schoolId, int actionUserId);

        /// <summary>Messages between two dates (yyyy-MM-dd), newest first; alertType empty = all.</summary>
        Task<List<MessageLogRow>> ListAsync(string? from, string? to, string? alertType, int tenantId, int schoolId, int actionUserId);
        Task<MessageSummary> SummaryAsync(string? from, string? to, string? alertType, int tenantId, int schoolId, int actionUserId);

        // Super Admin
        Task<(bool On, int SentThisMonth)> GetSchoolWhatsAppAsync(int schoolId, int superUserId);
        Task SaveSchoolWhatsAppAsync(int schoolId, bool on, int superUserId);
    }
}
