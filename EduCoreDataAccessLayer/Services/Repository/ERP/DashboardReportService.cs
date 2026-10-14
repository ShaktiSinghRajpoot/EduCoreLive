using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// Fee Dashboard (fee_dashboard.sql) and Attendance Overview (attendance_overview.sql).
    /// Both procedures are read-only and return many cursors; each cursor comes back by
    /// name as a list of rows (column -> value) for the page to draw.
    /// </summary>
    public class DashboardReportService : IDashboardReportService
    {
        private const string SpFee        = "core.sp_fee_dashboard";
        private const string SpAttendance = "core.sp_attendance_overview";
        private readonly PgExec _db;

        public DashboardReportService(PgExec db)
        {
            _db = db;
        }

        private static readonly string[] FeeCursors =
            { "summary", "months", "daily", "modes", "staff", "classes", "matrix", "heads", "families", "given", "problems" };
        private static readonly string[] AttendanceCursors = { "today", "sections", "weeks", "missing", "day" };

        public async Task<Dictionary<string, List<Dictionary<string, object?>>>> GetFeeDashboardAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new();

            var p = new List<NpgsqlParameter>
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId }
            };
            foreach (var c in FeeCursors)
                p.Add(new("p_" + c, NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fd_" + c });

            return CursorRows.From(await _db.ExecuteProcedureWithCursorsAsync(SpFee, p.ToArray()), FeeCursors);
        }

        public async Task<Dictionary<string, List<Dictionary<string, object?>>>> GetAttendanceOverviewAsync(
            string day, string from, string to, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new();

            var p = new List<NpgsqlParameter>
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_day",            NpgsqlDbType.Date)    { Value = (object?)Dates.Parse(day) ?? DBNull.Value },
                new("p_from",           NpgsqlDbType.Date)    { Value = (object?)Dates.Parse(from) ?? DBNull.Value },
                new("p_to",             NpgsqlDbType.Date)    { Value = (object?)Dates.Parse(to) ?? DBNull.Value }
            };
            // the procedure names its last cursor p_dayinfo
            foreach (var c in AttendanceCursors)
                p.Add(new(c == "day" ? "p_dayinfo" : "p_" + c, NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "ao_" + c });

            return CursorRows.From(await _db.ExecuteProcedureWithCursorsAsync(SpAttendance, p.ToArray()), AttendanceCursors);
        }
    }
}
