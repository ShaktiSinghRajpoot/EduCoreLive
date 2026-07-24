using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Daily student attendance — roster + save. Reports come later.</summary>
    public interface IAttendanceService
    {
        /// <summary>Sections that have active students in a class (Section dropdown).</summary>
        Task<List<string>> GetSectionsAsync(string className, int tenantId, int schoolId, int actionUserId);

        /// <summary>The class/section roster for a date, with any marks already made.</summary>
        Task<List<AttendanceStudent>> GetRosterAsync(
            string className, string? section, DateOnly date, int tenantId, int schoolId, int actionUserId);

        /// <summary>Upsert the whole class's marks for the date.</summary>
        Task<AttendanceSaveResult> SaveAsync(
            DateOnly date, List<AttendanceMark> marks, int tenantId, int schoolId, int actionUserId);
    }
}
