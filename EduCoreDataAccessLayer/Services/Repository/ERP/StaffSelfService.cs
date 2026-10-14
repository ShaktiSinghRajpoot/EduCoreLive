using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// My Leave / My Payslip (staff_self_service.sql). Every call passes the
    /// signed-in user's id; the procedures resolve the staff row from it and
    /// re-check it on every call. The leave rules themselves live in the HR
    /// procedure, which the self-service procedure calls.
    /// </summary>
    public class StaffSelfService : IStaffSelfService
    {
        private readonly PgExec _db;
        private readonly AppCache _cache;
        private readonly ILogger<StaffSelfService> _logger;
        private const string SpLeave   = "core.sp_staff_my_leave";
        private const string SpPayslip = "core.sp_staff_my_payslip";

        public StaffSelfService(PgExec db, AppCache cache, ILogger<StaffSelfService> logger)
        {
            _db = db;
            _cache = cache;
            _logger = logger;
        }

        private static bool InScope(int tenantId, int schoolId, int userId) =>
            tenantId > 1 && schoolId > 0 && userId > 0;

        // ── Who am I ──────────────────────────────────────────────────────────
        public async Task<MyStaffInfo?> GetMeAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId)) return null;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpLeave, LeaveParams("ME", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var row = ds.Tables[0].Rows[0];
            return new MyStaffInfo
            {
                StaffId      = IntVal(row, "staff_id"),
                FullName     = Str(row, "full_name"),
                EmployeeCode = NullStr(row, "employee_code"),
                Designation  = NullStr(row, "designation"),
                Department   = NullStr(row, "department"),
                Status       = Str(row, "status"),
                JoiningDate  = NullStr(row, "joining_date"),
                StaffType    = NullStr(row, "staff_type")
            };
        }

        public Task<bool> HasStaffRecordAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId)) return Task.FromResult(false);
            string key = AppCache.Key("isstaff:u" + actionUserId, tenantId, schoolId);
            return _cache.GetOrCreateAsync(key, async () =>
            {
                var me = await GetMeAsync(tenantId, schoolId, actionUserId);
                return me != null && me.IsCurrent;
            }, TimeSpan.FromMinutes(5));
        }

        public Task<bool> IsTeachingStaffAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId)) return Task.FromResult(false);
            string key = AppCache.Key("isteacher:u" + actionUserId, tenantId, schoolId);
            return _cache.GetOrCreateAsync(key, async () =>
            {
                var me = await GetMeAsync(tenantId, schoolId, actionUserId);
                return me != null && me.IsCurrent && me.IsTeachingType;
            }, TimeSpan.FromMinutes(5));
        }

        // ── My Leave ──────────────────────────────────────────────────────────
        public async Task<List<MyLeaveItem>> GetMyLeavesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<MyLeaveItem>();
            if (!InScope(tenantId, schoolId, actionUserId)) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpLeave, LeaveParams("LIST", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
                items.Add(new MyLeaveItem
                {
                    LeaveId         = IntVal(row, "leave_id"),
                    LeaveType       = Str(row, "leave_type"),
                    FromDate        = DbRead.NStr(row, "from_date"),
                    ToDate          = DbRead.NStr(row, "to_date"),
                    Days            = DecVal(row, "days"),
                    HalfDay         = BoolVal(row, "half_day"),
                    Reason          = NullStr(row, "reason"),
                    Status          = Str(row, "status"),
                    DecisionRemark  = NullStr(row, "decision_remark"),
                    AppliedAt       = DbRead.DateTimeN(row, "applied_at"),
                    AppliedByName   = NullStr(row, "applied_by_name"),
                    DecidedAt       = DbRead.DateTimeN(row, "decided_at"),
                    DecidedByName   = NullStr(row, "decided_by_name"),
                    CancelledAt     = DbRead.DateTimeN(row, "cancelled_at"),
                    CancelledByName = NullStr(row, "cancelled_by_name"),
                    CancelReason    = NullStr(row, "cancel_reason"),
                    CanCancel       = BoolVal(row, "can_cancel")
                });
            return items;
        }

        public async Task<List<StaffLeaveBalance>> GetMyBalanceAsync(string? anyDateInYear, int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<StaffLeaveBalance>();
            if (!InScope(tenantId, schoolId, actionUserId)) return items;

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpLeave,
                    LeaveParams("BALANCE", tenantId, schoolId, actionUserId, fromDate: anyDateInYear));
                if (ds.Tables.Count == 0) return items;

                foreach (DataRow row in ds.Tables[0].Rows)
                    items.Add(new StaffLeaveBalance
                    {
                        LeaveType = Str(row, "leave_type"),
                        Entitled  = NullDecVal(row, "entitled"),
                        Taken     = DecVal(row, "taken"),
                        Pending   = DecVal(row, "pending"),
                        Remaining = NullDecVal(row, "remaining"),
                        Year      = IntVal(row, "year")
                    });
            }
            catch (PostgresException ex)
            {
                // "You do not have a staff record" -- the page shows no balance.
                _logger.LogWarning(ex, "My leave BALANCE refused (SqlState {State})", ex.SqlState);
            }
            return items;
        }

        public Task<StaffLeaveResult> CountDaysAsync(string fromDate, string toDate, bool halfDay,
                                                     int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId))
                return Task.FromResult(new StaffLeaveResult { Message = "Invalid school scope." });

            return RunAsync("DAYS", LeaveParams("DAYS", tenantId, schoolId, actionUserId,
                fromDate: fromDate, toDate: toDate, halfDay: halfDay));
        }

        public Task<StaffLeaveResult> ApplyAsync(string? leaveType, string fromDate, string toDate, string? reason, bool halfDay,
                                                 int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId))
                return Task.FromResult(new StaffLeaveResult { Message = "Invalid school scope." });

            return RunAsync("APPLY", LeaveParams("APPLY", tenantId, schoolId, actionUserId,
                leaveType: leaveType, fromDate: fromDate, toDate: toDate, halfDay: halfDay, reason: reason));
        }

        public Task<StaffLeaveResult> CancelAsync(int leaveId, string? reason, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId))
                return Task.FromResult(new StaffLeaveResult { Message = "Invalid school scope." });

            return RunAsync("CANCEL", LeaveParams("CANCEL", tenantId, schoolId, actionUserId,
                leaveId: leaveId, reason: reason));
        }

        private async Task<StaffLeaveResult> RunAsync(string operation, NpgsqlParameter[] parameters)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpLeave, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new StaffLeaveResult { Message = "Nothing was changed." };

                var row = ds.Tables[0].Rows[0];
                return new StaffLeaveResult
                {
                    Success = true,
                    LeaveId = IntVal(row, "leave_id"),
                    Days    = DecVal(row, "days"),
                    Message = Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // The HR leave rules (cap reached, overlapping dates, already started...)
                // are written for people to read, so the proc's wording goes back.
                _logger.LogWarning(ex, "My leave {Op} refused (SqlState {State})", operation, ex.SqlState);
                return new StaffLeaveResult { Message = ex.MessageText };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "My leave {Op} unexpected error", operation);
                return new StaffLeaveResult { Message = "Could not save your leave request. Please try again." };
            }
        }

        // ── My Payslip ────────────────────────────────────────────────────────
        public async Task<List<MyPayslip>> GetMyPayslipsAsync(int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<MyPayslip>();
            if (!InScope(tenantId, schoolId, actionUserId)) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpPayslip, PayslipParams("LIST", tenantId, schoolId, actionUserId, null));
            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
                items.Add(MapPayslip(row));
            return items;
        }

        public async Task<MyPayslip?> GetMyPayslipAsync(int payrollId, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId, actionUserId) || payrollId <= 0) return null;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpPayslip, PayslipParams("GET", tenantId, schoolId, actionUserId, payrollId));
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;
            return MapPayslip(ds.Tables[0].Rows[0]);
        }

        private static MyPayslip MapPayslip(DataRow row) => new MyPayslip
        {
            PayrollId     = IntVal(row, "payroll_id"),
            FullName      = Str(row, "full_name"),
            EmployeeCode  = NullStr(row, "employee_code"),
            Designation   = NullStr(row, "designation"),
            Department    = NullStr(row, "department"),
            SchoolName    = NullStr(row, "school_name"),
            PayMonth      = IntVal(row, "pay_month"),
            PayYear       = IntVal(row, "pay_year"),
            MonthlySalary = DecVal(row, "monthly_salary"),
            WorkingDays   = DecVal(row, "working_days"),
            PaidDays      = DecVal(row, "paid_days"),
            Gross         = DecVal(row, "gross"),
            LopDays       = DecVal(row, "lop_days"),
            AbsentDays    = DecVal(row, "absent_days"),
            LopAmount     = DecVal(row, "lop_amount"),
            OtherAdd      = DecVal(row, "other_add"),
            OtherDeduct   = DecVal(row, "other_deduct"),
            NetPay        = DecVal(row, "net_pay"),
            Status        = Str(row, "status"),
            GeneratedAt   = DbRead.DateTimeN(row, "generated_at"),
            PaidAt        = DbRead.DateTimeN(row, "paid_at"),
            PaymentMode   = NullStr(row, "payment_mode")
        };

        // Positional: the procs' parameter order.
        private static NpgsqlParameter[] LeaveParams(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? leaveId = null, string? leaveType = null, string? fromDate = null, string? toDate = null,
            bool halfDay = false, string? reason = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_leave_id",       NpgsqlDbType.Integer) { Value = (object?)leaveId ?? DBNull.Value },
            new("p_leave_type",     NpgsqlDbType.Text)    { Value = (object?)leaveType ?? DBNull.Value },
            new("p_from_date",      NpgsqlDbType.Unknown) { Value = (object?)fromDate ?? DBNull.Value },
            new("p_to_date",        NpgsqlDbType.Unknown) { Value = (object?)toDate ?? DBNull.Value },
            new("p_half_day",       NpgsqlDbType.Boolean) { Value = halfDay },
            new("p_reason",         NpgsqlDbType.Text)    { Value = (object?)reason ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "my_leave_cursor" }
        };

        private static NpgsqlParameter[] PayslipParams(
            string operation, int tenantId, int schoolId, int actionUserId, int? payrollId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_payroll_id",     NpgsqlDbType.Integer) { Value = (object?)payrollId ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "my_payslip_cursor" }
        };

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static decimal DecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;
        private static decimal? NullDecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : null;
        private static bool BoolVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
    }
}
