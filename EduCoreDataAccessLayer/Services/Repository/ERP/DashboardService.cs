using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class DashboardService : IDashboardService
    {
        private readonly PgExec _db;
        private const string Sp = "core.sp_dashboard_summary";

        public DashboardService(PgExec db)
        {
            _db = db;
        }

        public async Task<DashboardSummary> GetSummaryAsync(int tenantId, int schoolId, int actionUserId)
        {
            var result = new DashboardSummary();
            if (tenantId <= 1 || schoolId <= 0) return result;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                Cur("p_kpi",        "db_kpi"),
                Cur("p_trend",      "db_trend"),
                Cur("p_classes",    "db_classes"),
                Cur("p_modes",      "db_modes"),
                Cur("p_defaulters", "db_defaulters"),
                Cur("p_recent",     "db_recent"),
                Cur("p_approvals",  "db_approvals"),
                Cur("p_events",     "db_events"),
                Cur("p_birthdays",  "db_birthdays")
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);

            // Nine cursors, in the order the proc opens them.
            if (Rows(ds, 0) is { Count: > 0 } kpi)
            {
                var row = kpi[0];
                result.Students            = IntVal(row, "students");
                result.Staff               = IntVal(row, "staff");
                result.TodayCollection     = DecVal(row, "today_collection");
                result.YesterdayCollection = DecVal(row, "yesterday_collection");
                result.Outstanding         = DecVal(row, "outstanding");
                result.DueStudents         = IntVal(row, "due_students");
                result.OnLeaveToday        = IntVal(row, "on_leave_today");
                result.PresentToday        = IntVal(row, "present_today");
                result.MarkedToday         = IntVal(row, "marked_today");
            }

            foreach (var row in Rows(ds, 1))
                result.Trend.Add(new DashboardTrendPoint
                    { Date = DbRead.Date(row, "d") ?? default, Amount = DecVal(row, "amount") });

            foreach (var row in Rows(ds, 2))
                result.Classes.Add(new DashboardClassCount
                    { ClassName = Str(row, "class_name"), Students = IntVal(row, "students") });

            foreach (var row in Rows(ds, 3))
                result.Modes.Add(new DashboardModeTotal
                    { Mode = Str(row, "mode"), Amount = DecVal(row, "amount") });

            foreach (var row in Rows(ds, 4))
                result.Defaulters.Add(new DashboardDefaulter
                {
                    StudentId   = IntVal(row, "student_id"),
                    PublicId    = GuidVal(row, "public_id"),
                    StudentName = Str(row, "student_name"),
                    ClassName   = NullStr(row, "class_name"),
                    Section     = NullStr(row, "section"),
                    Total       = DecVal(row, "total"),
                    Paid        = DecVal(row, "paid"),
                    Due         = DecVal(row, "due"),
                    LastPayment = DbRead.Date(row, "last_payment")
                });

            foreach (var row in Rows(ds, 5))
                result.Recent.Add(new DashboardReceipt
                {
                    ReceiptNo   = Str(row, "receipt_no"),
                    Amount      = DecVal(row, "amount"),
                    Mode        = NullStr(row, "payment_mode"),
                    PaymentDate = DbRead.Date(row, "payment_date"),
                    StudentName = Str(row, "student_name"),
                    ClassName   = NullStr(row, "class_name")
                });

            foreach (var row in Rows(ds, 6))
                result.Approvals.Add(new DashboardApproval
                {
                    LeaveId   = IntVal(row, "leave_id"),
                    FullName  = Str(row, "full_name"),
                    LeaveType = Str(row, "leave_type"),
                    FromDate  = DbRead.Date(row, "from_date"),
                    ToDate    = DbRead.Date(row, "to_date"),
                    Days      = IntVal(row, "days")
                });

            foreach (var row in Rows(ds, 7))
                result.Events.Add(new DashboardEvent
                {
                    Date    = DbRead.Date(row, "calendar_date") ?? default,
                    Title   = Str(row, "title"),
                    DayType = NullStr(row, "day_type")
                });

            foreach (var row in Rows(ds, 8))
                result.Birthdays.Add(new DashboardBirthday
                {
                    Name   = Str(row, "name"),
                    Who    = Str(row, "who"),
                    Detail = NullStr(row, "detail")
                });

            return result;
        }

        private static NpgsqlParameter Cur(string name, string value) =>
            new(name, NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = value };

        // A cursor that opened empty still produces a table, but a proc that
        // returned early produces fewer — so the index is always checked.
        private static List<DataRow> Rows(DataSet ds, int i) =>
            ds.Tables.Count > i ? ds.Tables[i].Rows.Cast<DataRow>().ToList() : new List<DataRow>();

        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static decimal DecVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToDecimal(r[c]) : 0m;
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
        private static Guid GuidVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? (Guid)r[c] : Guid.Empty;
    }
}
