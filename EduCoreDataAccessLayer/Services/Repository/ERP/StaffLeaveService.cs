using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class StaffLeaveService : IStaffLeaveService
    {
        private readonly PgExec _db;
        private const string Sp = "core.sp_staff_leave_manage";

        public StaffLeaveService(PgExec db)
        {
            _db = db;
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
                    FromDate       = DateVal(row, "from_date"),
                    ToDate         = DateVal(row, "to_date"),
                    Days           = IntVal(row, "days"),
                    Reason         = NullStr(row, "reason"),
                    Status         = Str(row, "status"),
                    DecisionRemark = NullStr(row, "decision_remark"),
                    AppliedAt      = TimeVal(row, "applied_at"),
                    DecidedAt      = TimeVal(row, "decided_at"),
                    OnLeaveToday   = BoolVal(row, "on_leave_today")
                });

            return items;
        }

        public async Task<StaffLeaveResult> ApplyAsync(
            int staffId, string leaveType, DateOnly fromDate, DateOnly toDate, string? reason,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffLeaveResult { Message = "Invalid school scope." };

            return await RunAsync(Params("APPLY", tenantId, schoolId, actionUserId,
                staffId: staffId, leaveType: leaveType,
                fromDate: fromDate, toDate: toDate, reason: reason));
        }

        public async Task<StaffLeaveResult> DecideAsync(
            int leaveId, string status, string? remark,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffLeaveResult { Message = "Invalid school scope." };

            return await RunAsync(Params("DECIDE", tenantId, schoolId, actionUserId,
                leaveId: leaveId, status: status, remark: remark));
        }

        private async Task<StaffLeaveResult> RunAsync(NpgsqlParameter[] parameters)
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
                    Days    = IntVal(row, "days"),
                    Message = Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // Every RAISE in this proc is a rule the office needs to read —
                // overlapping dates, an already-decided request — so its own
                // wording goes back to the screen.
                return new StaffLeaveResult { Message = ex.MessageText };
            }
        }

        // Positional: the proc's parameter order.
        private static NpgsqlParameter[] Params(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? leaveId = null, int? staffId = null, string? leaveType = null,
            DateOnly? fromDate = null, DateOnly? toDate = null, string? reason = null,
            string? status = null, string? remark = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_leave_id",       NpgsqlDbType.Integer) { Value = (object?)leaveId ?? DBNull.Value },
            new("p_staff_id",       NpgsqlDbType.Integer) { Value = (object?)staffId ?? DBNull.Value },
            new("p_leave_type",     NpgsqlDbType.Text)    { Value = (object?)leaveType ?? DBNull.Value },
            new("p_from_date",      NpgsqlDbType.Date)    { Value = fromDate.HasValue ? fromDate.Value : (object)DBNull.Value },
            new("p_to_date",        NpgsqlDbType.Date)    { Value = toDate.HasValue ? toDate.Value : (object)DBNull.Value },
            new("p_reason",         NpgsqlDbType.Text)    { Value = (object?)reason ?? DBNull.Value },
            new("p_status",         NpgsqlDbType.Text)    { Value = (object?)status ?? DBNull.Value },
            new("p_remark",         NpgsqlDbType.Text)    { Value = (object?)remark ?? DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor)
                { Direction = ParameterDirection.InputOutput, Value = "leave_cursor" }
        };

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static bool BoolVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
        private static DateOnly? DateVal(DataRow r, string c) =>
            Has(r, c) && r[c] != DBNull.Value ? DateOnly.FromDateTime(Convert.ToDateTime(r[c])) : null;
        private static DateTime? TimeVal(DataRow r, string c) =>
            Has(r, c) && r[c] != DBNull.Value ? Convert.ToDateTime(r[c]) : null;
    }


    public class StaffPayrollService : IStaffPayrollService
    {
        private readonly PgExec _db;
        private const string Sp = "core.sp_staff_payroll_manage";

        public StaffPayrollService(PgExec db)
        {
            _db = db;
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
                    PayrollId    = IntVal(row, "payroll_id"),
                    StaffId      = IntVal(row, "staff_id"),
                    FullName     = Str(row, "full_name"),
                    EmployeeCode = NullStr(row, "employee_code"),
                    Designation  = NullStr(row, "designation"),
                    Department   = NullStr(row, "department"),
                    PayMonth     = IntVal(row, "pay_month"),
                    PayYear      = IntVal(row, "pay_year"),
                    Gross        = DecVal(row, "gross"),
                    LopDays      = IntVal(row, "lop_days"),
                    LopAmount    = DecVal(row, "lop_amount"),
                    OtherDeduct  = DecVal(row, "other_deduct"),
                    NetPay       = DecVal(row, "net_pay"),
                    Status       = Str(row, "status"),
                    PaidAt       = TimeVal(row, "paid_at")
                });

            return items;
        }

        public async Task<StaffPayrollResult> RunAsync(
            int month, int year, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffPayrollResult { Message = "Invalid school scope." };

            return await ExecAsync(Params("RUN", tenantId, schoolId, actionUserId,
                month: month, year: year));
        }

        public async Task<StaffPayrollResult> MarkPaidAsync(
            int payrollId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StaffPayrollResult { Message = "Invalid school scope." };

            return await ExecAsync(Params("MARK_PAID", tenantId, schoolId, actionUserId,
                payrollId: payrollId));
        }

        private async Task<StaffPayrollResult> ExecAsync(NpgsqlParameter[] parameters)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new StaffPayrollResult { Message = "Nothing was changed." };

                var row = ds.Tables[0].Rows[0];
                return new StaffPayrollResult
                {
                    Success     = true,
                    Generated   = IntVal(row, "generated"),
                    Skipped     = IntVal(row, "skipped"),
                    WorkingDays = IntVal(row, "working_days"),
                    Message     = Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                return new StaffPayrollResult { Message = ex.MessageText };
            }
        }

        private static NpgsqlParameter[] Params(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? month = null, int? year = null, int? payrollId = null,
            string? department = null) => new NpgsqlParameter[]
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
                { Direction = ParameterDirection.InputOutput, Value = "payroll_cursor" }
        };

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static decimal DecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
        private static DateTime? TimeVal(DataRow r, string c) =>
            Has(r, c) && r[c] != DBNull.Value ? Convert.ToDateTime(r[c]) : null;
    }
}
