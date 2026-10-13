using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Staff attendance and substitute teachers (staff_attendance.sql).</summary>
    public interface IStaffAttendanceService
    {
        Task<StaffDaySheet> GetDayAsync(string date, int tenantId, int schoolId, int actionUserId);

        /// <summary>Save one day's marks. A blank status leaves that person unmarked.</summary>
        Task<(bool Success, string Message)> SaveDayAsync(string date, List<StaffDayRow> marks,
                                                          int tenantId, int schoolId, int actionUserId);

        /// <summary>month = "yyyy-MM".</summary>
        Task<StaffMonthRegister> GetMonthAsync(string month, int tenantId, int schoolId, int actionUserId);

        Task<(List<SubstitutionNeed> Needs, List<TeacherLoad> Teachers)> GetSubstitutionDayAsync(
            string date, int tenantId, int schoolId, int actionUserId);

        Task<(bool Success, string Message)> AssignSubstituteAsync(string date, int sectionId, int periodSeq, int substituteId,
                                                                   int tenantId, int schoolId, int actionUserId);

        Task<(bool Success, string Message)> RemoveSubstituteAsync(string date, int sectionId, int periodSeq,
                                                                   int tenantId, int schoolId, int actionUserId);

        /// <summary>The signed-in teacher's substitutions from today on.</summary>
        Task<List<MySubstitution>> GetMySubstitutionsAsync(int tenantId, int schoolId, int actionUserId);
    }
}
