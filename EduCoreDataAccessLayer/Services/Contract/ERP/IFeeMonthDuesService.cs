using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Month-wise fee dues and the "may have left school" attendance check
    /// (fee_month_dues.sql).
    /// </summary>
    public interface IFeeMonthDuesService
    {
        /// <summary>Months, classes and children with dues falling due between two months (from may be empty).</summary>
        Task<FeeMonthDues> GetAsync(string academicYear, string? fromMonth, string? uptoMonth, string? className, string? section,
                                    int tenantId, int schoolId, int actionUserId);

        /// <summary>One child's attendance month by month, last day present and the absent streak.</summary>
        Task<AttendanceBrief?> GetAttendanceAsync(int studentId, string academicYear, int tenantId, int schoolId, int actionUserId);

        // ── chasing (fee_dues_followup.sql) ──
        Task<List<FeeFollowup>> GetFollowupsAsync(int studentId, int tenantId, int schoolId, int actionUserId);
        Task<FeeDuesResult> AddFollowupAsync(int studentId, string note, string? promiseDate, int tenantId, int schoolId, int actionUserId);
        Task<FeeDuesResult> FollowupDoneAsync(int followupId, int tenantId, int schoolId, int actionUserId);
        Task<FeeDuesResult> SetNoChaseAsync(int studentId, string? reason, string? until, bool on, int tenantId, int schoolId, int actionUserId);
        Task<FeeDuesSettings> GetSettingsAsync(int tenantId, int schoolId, int actionUserId);
        Task<FeeDuesResult> SaveSettingsAsync(FeeDuesSettings s, int tenantId, int schoolId, int actionUserId);
        Task<List<LateFeeLine>> PreviewLateFeesAsync(string academicYear, List<int>? studentIds, int tenantId, int schoolId, int actionUserId);
        Task<FeeDuesResult> ApplyLateFeesAsync(string academicYear, List<int>? studentIds, int tenantId, int schoolId, int actionUserId);
    }
}
