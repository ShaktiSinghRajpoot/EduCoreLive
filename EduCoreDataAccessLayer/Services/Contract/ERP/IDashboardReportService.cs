namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Read-only dashboards (Fee Dashboard, Attendance Overview). Each returns the
    /// procedure's cursors by name, every row as column -> value, because the page
    /// only draws them; there is no business logic on these rows in C#.
    /// </summary>
    public interface IDashboardReportService
    {
        /// <summary>core.sp_fee_dashboard: summary, months, daily, modes, staff, classes, matrix, heads, families, given, problems.</summary>
        Task<Dictionary<string, List<Dictionary<string, object?>>>> GetFeeDashboardAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>core.sp_attendance_overview: today, sections, weeks, missing, day.</summary>
        Task<Dictionary<string, List<Dictionary<string, object?>>>> GetAttendanceOverviewAsync(
            string day, string from, string to, int tenantId, int schoolId, int actionUserId);
    }
}
