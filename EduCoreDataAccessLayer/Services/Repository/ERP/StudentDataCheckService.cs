using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>Students › Data Checks: core.sp_student_data_checks (Summary | List | AssignRolls).</summary>
    public class StudentDataCheckService : IStudentDataCheckService
    {
        private const string Sp = "core.sp_student_data_checks";
        private readonly PgExec _db;
        private readonly ILogger<StudentDataCheckService> _logger;

        public StudentDataCheckService(PgExec db, ILogger<StudentDataCheckService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<Dictionary<string, object?>>> GetSummaryAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new();
            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, Params("Summary", tenantId, schoolId, actionUserId));
            return CursorRows.From(ds.Tables.Count > 0 ? ds.Tables[0] : null);
        }

        public async Task<List<Dictionary<string, object?>>> GetListAsync(string check, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(check)) return new();
            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, Params("List", tenantId, schoolId, actionUserId, check));
            return CursorRows.From(ds.Tables.Count > 0 ? ds.Tables[0] : null);
        }

        public async Task<(bool Success, string Message)> AssignRollsAsync(string className, string? section, string mode,
                                                                           int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (false, "Invalid request.");
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp,
                    Params("AssignRolls", tenantId, schoolId, actionUserId, null, className, section ?? "", mode));
                var msg = ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0 ? ds.Tables[0].Rows[0]["message"]?.ToString() : null;
                return (true, msg ?? "Done.");
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Assign roll numbers rejected for school {SchoolId}. SqlState {SqlState}", schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
        }

        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId,
                                                string? check = null, string? className = null, string? section = null,
                                                string? mode = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_check",          NpgsqlDbType.Text)    { Value = (object?)check ?? DBNull.Value },
            new("p_class",          NpgsqlDbType.Text)    { Value = (object?)className ?? DBNull.Value },
            new("p_section",        NpgsqlDbType.Text)    { Value = (object?)section ?? DBNull.Value },
            new("p_mode",           NpgsqlDbType.Text)    { Value = (object?)mode ?? "missing" },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "data_checks_cursor" }
        };
    }
}
