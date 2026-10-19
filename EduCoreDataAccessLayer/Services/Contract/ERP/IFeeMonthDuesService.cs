using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Month-wise fee dues and the "may have left school" attendance check
    /// (fee_month_dues.sql).
    /// </summary>
    public interface IFeeMonthDuesService
    {
        /// <summary>Months, classes and children with dues falling due up to the end of a month.</summary>
        Task<FeeMonthDues> GetAsync(string academicYear, string? uptoMonth, string? className, string? section,
                                    int tenantId, int schoolId, int actionUserId);

        /// <summary>One child's attendance month by month, last day present and the absent streak.</summary>
        Task<AttendanceBrief?> GetAttendanceAsync(int studentId, string academicYear, int tenantId, int schoolId, int actionUserId);
    }
}
