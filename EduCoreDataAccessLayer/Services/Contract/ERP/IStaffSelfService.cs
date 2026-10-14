using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Staff self-service: the signed-in user's own leave and payslips.
    /// There is no staff id parameter anywhere on purpose -- the procedures work
    /// out the staff row from the user id, so nobody can ask for someone else's.
    /// </summary>
    public interface IStaffSelfService
    {
        Task<MyStaffInfo?> GetMeAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>True when the user has a current (not Inactive) staff record here.
        /// Cached for 5 minutes: it is asked on every menu render.</summary>
        Task<bool> HasStaffRecordAsync(int tenantId, int schoolId, int actionUserId);

        /// <summary>Current staff whose type is Teaching (or not recorded). Cached 5 min.</summary>
        Task<bool> IsTeachingStaffAsync(int tenantId, int schoolId, int actionUserId);

        Task<List<MyLeaveItem>> GetMyLeavesAsync(int tenantId, int schoolId, int actionUserId);
        Task<List<StaffLeaveBalance>> GetMyBalanceAsync(string? anyDateInYear, int tenantId, int schoolId, int actionUserId);
        Task<StaffLeaveResult> CountDaysAsync(string fromDate, string toDate, bool halfDay, int tenantId, int schoolId, int actionUserId);
        Task<StaffLeaveResult> ApplyAsync(string? leaveType, string fromDate, string toDate, string? reason, bool halfDay,
                                          int tenantId, int schoolId, int actionUserId);
        Task<StaffLeaveResult> CancelAsync(int leaveId, string? reason, int tenantId, int schoolId, int actionUserId);

        Task<List<MyPayslip>> GetMyPayslipsAsync(int tenantId, int schoolId, int actionUserId);
        Task<MyPayslip?> GetMyPayslipAsync(int payrollId, int tenantId, int schoolId, int actionUserId);
    }
}
