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
    public class StaffLeaveService : IStaffLeaveService
    {
        private readonly PgExec _db;
        private readonly ILogger<StaffLeaveService> _logger;
        private const string Sp = "core.sp_staff_leave_manage";

        public StaffLeaveService(PgExec db, ILogger<StaffLeaveService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<StaffLeaveItem>> GetLeavesAsync(
            int tenantId, int schoolId, int actionUserId, int? staffId = null, string? status = null)
        {
            var items = new List<StaffLeaveItem>();
            if (tenantId <= 1 || schoolId <= 0) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("LIST", tenantId, schoolId, actionUserId,
                           staffId: staffId, status: status));

            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
                items.Add(new StaffLeaveItem
                {
                    LeaveId        = IntVal(row, "leave_id"),
                    StaffId        = IntVal(row, "staff_id"),
                    FullName       = Str(row, "full_name"),
                    EmployeeCode   = NullStr(row, "employee_code"),
                    Designation    = NullStr(row, "designation"),
                    LeaveType      = Str(row, "leave_type"),
                    FromDate       = DbRead.NStr(row, "from_date"),
                    ToDate         = DbRead.NStr(row, "to_date"),
                    Days           = DecVal(row, "days"),
                    HalfDay        = BoolVal(row, "half_day"),
                    Reason         = NullStr(row, "reason"),
                    Status         = Str(row, "status"),
                    DecisionRemark = NullStr(row, "decision_remark"),
                    AppliedAt      = DbRead.DateTimeN(row, "applied_at"),
                    DecidedAt      = DbRead.DateTimeN(row, "decided_at"),
                    CancelReason   = NullStr(row, "cancel_reason"),
                    CancelledAt    = DbRead.DateTimeN(row, "cancelled_at"),
                    OnLeaveToday   = BoolVal(row, "on_leave_today")
                });

            return items;
        }

        public async Task<StaffLeaveResult> ApplyAsync(
            int staffId, string leaveType, string fromDate, string toDate, string? reason, bool halfDay,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffLeaveResult { Message = "Invalid school scope." };

            return await RunAsync("APPLY", Params("APPLY", tenantId, schoolId, actionUserId,
                staffId: staffId, leaveType: leaveType,
                fromDate: fromDate, toDate: toDate, reason: reason, halfDay: halfDay));
        }

        public async Task<StaffLeaveResult> DecideAsync(
            int leaveId, string status, string? remark,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffLeaveResult { Message = "Invalid school scope." };

            return await RunAsync("DECIDE", Params("DECIDE", tenantId, schoolId, actionUserId,
                leaveId: leaveId, status: status, remark: remark));
        }

        public async Task<StaffLeaveResult> CancelAsync(
            int leaveId, string? reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffLeaveResult { Message = "Invalid school scope." };

            return await RunAsync("CANCEL", Params("CANCEL", tenantId, schoolId, actionUserId,
                leaveId: leaveId, remark: reason));
        }

        public async Task<StaffLeaveResult> CountDaysAsync(
            string fromDate, string toDate, bool halfDay, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffLeaveResult { Message = "Invalid school scope." };

            return await RunAsync("DAYS", Params("DAYS", tenantId, schoolId, actionUserId,
                fromDate: fromDate, toDate: toDate, halfDay: halfDay));
        }

        public async Task<List<StaffLeaveBalance>> GetBalanceAsync(
            int staffId, string? anyDateInYear, int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<StaffLeaveBalance>();
            if (tenantId <= 1 || schoolId <= 0 || staffId <= 0) return items;

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    Sp, Params("BALANCE", tenantId, schoolId, actionUserId, staffId: staffId, fromDate: anyDateInYear));
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
                _logger.LogWarning(ex, "Leave BALANCE refused (SqlState {State})", ex.SqlState);
            }
            return items;
        }

        private async Task<StaffLeaveResult> RunAsync(string operation, NpgsqlParameter[] parameters)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
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
                // Every RAISE in this proc is a rule the office needs to read —
                // overlapping dates, no balance left, an already-decided request —
                // so its own wording goes back to the screen.
                _logger.LogWarning(ex, "Leave {Op} refused (SqlState {State})", operation, ex.SqlState);
                return new StaffLeaveResult { Message = ex.MessageText };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Leave {Op} unexpected error", operation);
                return new StaffLeaveResult { Message = "Could not save the leave request. Please try again." };
            }
        }

        // Positional: the proc's parameter order. p_half_day comes AFTER p_result.
        private static NpgsqlParameter[] Params(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? leaveId = null, int? staffId = null, string? leaveType = null,
            string? fromDate = null, string? toDate = null, string? reason = null,
            string? status = null, string? remark = null, bool halfDay = false) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_leave_id",       NpgsqlDbType.Integer) { Value = (object?)leaveId ?? DBNull.Value },
            new("p_staff_id",       NpgsqlDbType.Integer) { Value = (object?)staffId ?? DBNull.Value },
            new("p_leave_type",     NpgsqlDbType.Text)    { Value = (object?)leaveType ?? DBNull.Value },
            new("p_from_date",      NpgsqlDbType.Unknown)    { Value = (object?)fromDate ?? DBNull.Value },
            new("p_to_date",        NpgsqlDbType.Unknown)    { Value = (object?)toDate ?? DBNull.Value },
            new("p_reason",         NpgsqlDbType.Text)    { Value = (object?)reason ?? DBNull.Value },
            new("p_status",         NpgsqlDbType.Text)    { Value = (object?)status ?? DBNull.Value },
            new("p_remark",         NpgsqlDbType.Text)    { Value = (object?)remark ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "leave_cursor" },
            new("p_half_day",       NpgsqlDbType.Boolean) { Value = halfDay }
        };

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static decimal DecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;
        private static decimal? NullDecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : null;
        private static bool BoolVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
    }


    public class StaffPayrollService : IStaffPayrollService
    {
        private readonly PgExec _db;
        private readonly ILogger<StaffPayrollService> _logger;
        private const string Sp = "core.sp_staff_payroll_manage";
        private const string SpAdjust = "core.sp_staff_payroll_adjust";

        public StaffPayrollService(PgExec db, ILogger<StaffPayrollService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<StaffPayrollItem>> GetPayrollAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId, string? department = null)
        {
            var items = new List<StaffPayrollItem>();
            if (tenantId <= 1 || schoolId <= 0 || month < 1 || month > 12 || year < 2000) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, Params("LIST", tenantId, schoolId, actionUserId,
                           month: month, year: year, department: department));

            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
                items.Add(new StaffPayrollItem
                {
                    PayrollId     = IntVal(row, "payroll_id"),
                    StaffId       = IntVal(row, "staff_id"),
                    FullName      = Str(row, "full_name"),
                    EmployeeCode  = NullStr(row, "employee_code"),
                    Designation   = NullStr(row, "designation"),
                    Department    = NullStr(row, "department"),
                    PayMonth      = IntVal(row, "pay_month"),
                    PayYear       = IntVal(row, "pay_year"),
                    MonthlySalary = DecVal(row, "monthly_salary"),
                    WorkingDays   = DecVal(row, "working_days"),
                    PaidDays      = DecVal(row, "paid_days"),
                    Gross         = DecVal(row, "gross"),
                    LopDays       = DecVal(row, "lop_days"),
                    LopAmount     = DecVal(row, "lop_amount"),
                    OtherAdd      = DecVal(row, "other_add"),
                    OtherDeduct   = DecVal(row, "other_deduct"),
                    NetPay        = DecVal(row, "net_pay"),
                    Status        = Str(row, "status"),
                    GeneratedAt   = DbRead.DateTimeN(row, "generated_at"),
                    PaidAt        = DbRead.DateTimeN(row, "paid_at"),
                    PaymentMode   = NullStr(row, "payment_mode"),
                    PaymentReference = NullStr(row, "payment_reference"),
                    PaidByName    = NullStr(row, "paid_by_name")
                });

            return items;
        }

        public async Task<StaffPayrollResult> RunAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffPayrollResult { Message = "Invalid school scope." };

            return await ExecAsync(Sp, "RUN", Params("RUN", tenantId, schoolId, actionUserId,
                month: month, year: year));
        }

        public async Task<StaffPayrollResult> MarkPaidAsync(
            int payrollId, string? paymentMode, string? paymentReference,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffPayrollResult { Message = "Invalid school scope." };

            return await ExecAsync(Sp, "MARK_PAID", Params("MARK_PAID", tenantId, schoolId, actionUserId,
                payrollId: payrollId, paymentMode: paymentMode, paymentReference: paymentReference));
        }

        public async Task<List<StaffPayrollHistory>> GetHistoryAsync(
            int payrollId, int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<StaffPayrollHistory>();
            if (tenantId <= 1 || schoolId <= 0 || payrollId <= 0) return items;

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    Sp, Params("HISTORY", tenantId, schoolId, actionUserId, payrollId: payrollId));
                if (ds.Tables.Count == 0) return items;

                foreach (DataRow row in ds.Tables[0].Rows)
                    items.Add(new StaffPayrollHistory
                    {
                        Action           = Str(row, "action"),
                        NetPay           = NullDecVal(row, "net_pay"),
                        PaymentMode      = NullStr(row, "payment_mode"),
                        PaymentReference = NullStr(row, "payment_reference"),
                        Note             = NullStr(row, "note"),
                        ActionAt         = DbRead.DateTimeN(row, "action_at"),
                        ActionByName     = NullStr(row, "action_by_name")
                    });
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Payroll HISTORY refused (SqlState {State})", ex.SqlState);
            }
            return items;
        }

        public async Task<List<StaffPayrollAdjustment>> GetAdjustmentsAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<StaffPayrollAdjustment>();
            if (tenantId <= 1 || schoolId <= 0 || month < 1 || month > 12 || year < 2000) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpAdjust, AdjustParams("LIST", tenantId, schoolId, actionUserId, month: month, year: year));
            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
                items.Add(new StaffPayrollAdjustment
                {
                    AdjustmentId     = IntVal(row, "adjustment_id"),
                    StaffId          = IntVal(row, "staff_id"),
                    FullName         = Str(row, "full_name"),
                    EmployeeCode     = NullStr(row, "employee_code"),
                    Kind             = Str(row, "kind"),
                    Amount           = DecVal(row, "amount"),
                    Reason           = Str(row, "reason"),
                    PaymentMode      = NullStr(row, "payment_mode"),
                    PaymentReference = NullStr(row, "payment_reference"),
                    CreatedAt        = DbRead.DateTimeN(row, "created_at"),
                    CreatedByName    = NullStr(row, "created_by_name"),
                    IsVoid           = Has(row, "is_void") && row["is_void"] != DBNull.Value && Convert.ToBoolean(row["is_void"]),
                    VoidedAt         = DbRead.DateTimeN(row, "voided_at"),
                    VoidReason       = NullStr(row, "void_reason")
                });
            return items;
        }

        public async Task<StaffPayrollResult> AddAdjustmentAsync(
            int staffId, int month, int year, string? kind, decimal amount, string? reason,
            string? paymentMode, string? paymentReference,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffPayrollResult { Message = "Invalid school scope." };

            return await ExecAsync(SpAdjust, "ADJUST_ADD", AdjustParams("ADD", tenantId, schoolId, actionUserId,
                staffId: staffId, month: month, year: year, kind: kind, amount: amount, reason: reason,
                paymentMode: paymentMode, paymentReference: paymentReference));
        }

        public async Task<StaffPayrollResult> VoidAdjustmentAsync(
            int adjustmentId, string? reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffPayrollResult { Message = "Invalid school scope." };

            return await ExecAsync(SpAdjust, "ADJUST_VOID", AdjustParams("VOID", tenantId, schoolId, actionUserId,
                adjustmentId: adjustmentId, reason: reason));
        }

        private async Task<StaffPayrollResult> ExecAsync(string proc, string operation, NpgsqlParameter[] parameters)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(proc, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new StaffPayrollResult { Message = "Nothing was changed." };

                var row = ds.Tables[0].Rows[0];
                return new StaffPayrollResult
                {
                    Success      = true,
                    Generated    = IntVal(row, "generated"),
                    Skipped      = IntVal(row, "skipped"),
                    WorkingDays  = DecVal(row, "working_days"),
                    AdjustmentId = IntVal(row, "adjustment_id"),
                    Message      = Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // Payroll rules (paid already, no reference, future month...) are
                // written for the office to read, so the proc's wording is returned.
                _logger.LogWarning(ex, "Payroll {Op} refused (SqlState {State})", operation, ex.SqlState);
                return new StaffPayrollResult { Message = ex.MessageText };
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Payroll {Op} unexpected error", operation);
                return new StaffPayrollResult { Message = "Could not complete the payroll action. Nothing was changed." };
            }
        }

        // Positional: the proc's parameter order. The payment pair comes AFTER p_result.
        private static NpgsqlParameter[] Params(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? month = null, int? year = null, int? payrollId = null,
            string? department = null, string? paymentMode = null, string? paymentReference = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_month",          NpgsqlDbType.Integer) { Value = (object?)month ?? DBNull.Value },
            new("p_year",           NpgsqlDbType.Integer) { Value = (object?)year ?? DBNull.Value },
            new("p_payroll_id",     NpgsqlDbType.Integer) { Value = (object?)payrollId ?? DBNull.Value },
            new("p_department",     NpgsqlDbType.Text)    { Value = (object?)department ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "payroll_cursor" },
            new("p_payment_mode",      NpgsqlDbType.Text) { Value = (object?)paymentMode ?? DBNull.Value },
            new("p_payment_reference", NpgsqlDbType.Text) { Value = (object?)paymentReference ?? DBNull.Value }
        };

        private static NpgsqlParameter[] AdjustParams(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? adjustmentId = null, int? staffId = null, int? month = null, int? year = null,
            string? kind = null, decimal? amount = null, string? reason = null,
            string? paymentMode = null, string? paymentReference = null) => new NpgsqlParameter[]
        {
            new("p_operation",         NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",         NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",         NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id",    NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_adjustment_id",     NpgsqlDbType.Integer) { Value = (object?)adjustmentId ?? DBNull.Value },
            new("p_staff_id",          NpgsqlDbType.Integer) { Value = (object?)staffId ?? DBNull.Value },
            new("p_month",             NpgsqlDbType.Integer) { Value = (object?)month ?? DBNull.Value },
            new("p_year",              NpgsqlDbType.Integer) { Value = (object?)year ?? DBNull.Value },
            new("p_kind",              NpgsqlDbType.Text)    { Value = (object?)kind ?? DBNull.Value },
            new("p_amount",            NpgsqlDbType.Numeric) { Value = (object?)amount ?? DBNull.Value },
            new("p_reason",            NpgsqlDbType.Text)    { Value = (object?)reason ?? DBNull.Value },
            new("p_payment_mode",      NpgsqlDbType.Text)    { Value = (object?)paymentMode ?? DBNull.Value },
            new("p_payment_reference", NpgsqlDbType.Text)    { Value = (object?)paymentReference ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "payroll_adjust_cursor" }
        };

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static decimal DecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;
        private static decimal? NullDecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : null;
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
    }
}
