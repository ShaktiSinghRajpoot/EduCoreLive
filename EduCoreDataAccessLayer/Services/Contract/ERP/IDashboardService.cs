using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IDashboardService
    {
        /// <summary>Everything the landing dashboard draws, in one round trip —
        /// a dozen cards would otherwise be a dozen calls on every sign-in.</summary>
        Task<DashboardSummary> GetSummaryAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Fills the attendance section: staff today, student and staff defaulters.</summary>
        Task FillAttendanceAsync(DashboardSummary model, int tenantId, int schoolId, int actionUserId);
    }
}
