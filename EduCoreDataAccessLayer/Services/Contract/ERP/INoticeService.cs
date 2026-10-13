using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Announcements / Notice Board (announcements.sql).</summary>
    public interface INoticeService
    {
        /// <summary>Live notices for the signed-in user (pinned first), with whether they read each.</summary>
        Task<List<Notice>> GetBoardAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Every notice including expired ones, for people who manage notices.</summary>
        Task<List<Notice>> GetAllAsync(int tenantId, int schoolId, int actionUserId);

        Task<Notice?> GetAsync(int id, int tenantId, int schoolId, int actionUserId);

        Task<List<NoticeReader>> GetSeenByAsync(int id, int tenantId, int schoolId, int actionUserId);

        /// <summary>Mark one notice (id) or every notice (null) as read by this user.</summary>
        Task MarkReadAsync(int? id, int tenantId, int schoolId, int actionUserId);

        /// <summary>New notice when n.Id is 0, otherwise an edit.</summary>
        Task<(bool Success, string Message)> SaveAsync(Notice n, int tenantId, int schoolId, int actionUserId);

        Task<(bool Success, string Message)> DeleteAsync(int id, int tenantId, int schoolId, int actionUserId);
    }
}
