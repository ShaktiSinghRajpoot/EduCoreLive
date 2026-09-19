using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IStaffLeaveService
    {
        /// <summary>Leave requests, newest first. status null/empty = all.</summary>
        Task<List<StaffLeaveItem>> GetLeavesAsync(
            int tenantId, int schoolId, int actionUserId,
            int? staffId = null, string? status = null);

        /// <summary>Applies for leave. The proc counts working days (Sundays excluded)
        /// and refuses a range overlapping an existing pending or approved request.</summary>
        Task<StaffLeaveResult> ApplyAsync(
            int staffId, string leaveType, DateOnly fromDate, DateOnly toDate, string? reason,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>Approve or reject. A request that was already decided is refused,
        /// so the record of who decided it and when survives.</summary>
        Task<StaffLeaveResult> DecideAsync(
            int leaveId, string status, string? remark,
            int tenantId, int schoolId, int actionUserId);
    }

    public interface IStaffPayrollService
    {
        Task<List<StaffPayrollItem>> GetPayrollAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId,
            string? department = null);

        /// <summary>Generates draft payslips for every active staff member. Payslips
        /// already marked Paid are left untouched and reported as skipped.</summary>
        Task<StaffPayrollResult> RunAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId);

        Task<StaffPayrollResult> MarkPaidAsync(
            int payrollId, int tenantId, int schoolId, int actionUserId);
    }
}
