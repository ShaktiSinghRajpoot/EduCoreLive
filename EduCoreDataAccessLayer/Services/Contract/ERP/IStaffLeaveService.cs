using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IStaffLeaveService
    {
        /// <summary>Leave requests, newest first. status null/empty = all.</summary>
        Task<List<StaffLeaveItem>> GetLeavesAsync(
            int tenantId, int schoolId, int actionUserId,
            int? staffId = null, string? status = null);

        /// <summary>Applies for leave. The proc counts school working days, checks the
        /// yearly entitlement, and refuses an overlap, an inactive staff member, or
        /// dates outside the employment.</summary>
        Task<StaffLeaveResult> ApplyAsync(
            int staffId, string leaveType, string fromDate, string toDate, string? reason, bool halfDay,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>Approve or reject. A request that was already decided is refused,
        /// so the record of who decided it and when survives.</summary>
        Task<StaffLeaveResult> DecideAsync(
            int leaveId, string status, string? remark,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>Withdraws a pending request, or an approved one that has not
        /// started and is not in a paid month. A reason is required.</summary>
        Task<StaffLeaveResult> CancelAsync(
            int leaveId, string? reason, int tenantId, int schoolId, int actionUserId);

        /// <summary>How many working days APPLY would count (form preview).</summary>
        Task<StaffLeaveResult> CountDaysAsync(
            string fromDate, string toDate, bool halfDay, int tenantId, int schoolId, int actionUserId);

        /// <summary>Per-type entitlement / taken / pending / left for one year.</summary>
        Task<List<StaffLeaveBalance>> GetBalanceAsync(
            int staffId, string? anyDateInYear, int tenantId, int schoolId, int actionUserId);
    }

    public interface IStaffPayrollService
    {
        Task<List<StaffPayrollItem>> GetPayrollAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId,
            string? department = null);

        /// <summary>Generates draft payslips (pro-rata, LOP, adjustments). Payslips
        /// already marked Paid are left untouched and reported as skipped.</summary>
        Task<StaffPayrollResult> RunAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId);

        /// <summary>Marks a payslip paid with how it was paid (Cash / Bank Transfer /
        /// Cheque / UPI) and the reference (required unless Cash).</summary>
        Task<StaffPayrollResult> MarkPaidAsync(
            int payrollId, string? paymentMode, string? paymentReference,
            int tenantId, int schoolId, int actionUserId);

        /// <summary>The money trail of one payslip's staff member and month.</summary>
        Task<List<StaffPayrollHistory>> GetHistoryAsync(
            int payrollId, int tenantId, int schoolId, int actionUserId);

        Task<List<StaffPayrollAdjustment>> GetAdjustmentsAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId);

        Task<StaffPayrollResult> AddAdjustmentAsync(
            int staffId, int month, int year, string? kind, decimal amount, string? reason,
            string? paymentMode, string? paymentReference,
            int tenantId, int schoolId, int actionUserId);

        Task<StaffPayrollResult> VoidAdjustmentAsync(
            int adjustmentId, string? reason, int tenantId, int schoolId, int actionUserId);
    }
}
