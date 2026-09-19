using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Daily student attendance — roster + save. Reports come later.</summary>
    public interface IAttendanceService
    {
        /// <summary>Sections that have active students in a class (Section dropdown).</summary>
        Task<List<string>> GetSectionsAsync(string className, int tenantId, int schoolId, int actionUserId);

        /// <summary>The class/section roster for a date, with any marks already made.</summary>
        // One student's attendance for a session, plus the day marks for one month.
        // The class register (sp_attendance_month_register) answers the other axis —
        // whole class, one month — and both share the same day/status conventions.
        Task<StudentAttendanceSummary> GetStudentAttendanceAsync(
            int studentId, int tenantId, int schoolId, int actionUserId,
            string? academicYear = null, int? month = null, int? year = null);

        Task<List<AttendanceStudent>> GetRosterAsync(
            string className, string? section, DateOnly date, int tenantId, int schoolId, int actionUserId);

        /// <summary>Upsert the whole class's marks for the date.</summary>
        Task<AttendanceSaveResult> SaveAsync(
            DateOnly date, List<AttendanceMark> marks, int tenantId, int schoolId, int actionUserId);

        /// <summary>A class/section's full month of attendance for the report views.</summary>
        Task<AttendanceMonthRegister> GetMonthRegisterAsync(
            string className, string? section, int month, int year, int tenantId, int schoolId, int actionUserId);
    }
}
