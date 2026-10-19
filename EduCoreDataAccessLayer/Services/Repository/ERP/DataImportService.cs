using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class DataImportService : IDataImportService
    {
        private readonly PgExec _db;
        private readonly ILogger<DataImportService> _logger;

        public DataImportService(PgExec db, ILogger<DataImportService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<(bool Success, string Message)> AddOpeningDueAsync(string admissionNo, decimal amount, string? note,
                                                                              string? fromSession, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return (false, "Invalid school.");
            if (string.IsNullOrWhiteSpace(admissionNo))
                return (false, "Admission no is required.");

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_admission_no",   NpgsqlDbType.Varchar) { Value = admissionNo.Trim() },
                new("p_amount",         NpgsqlDbType.Numeric) { Value = amount },
                new("p_note",           NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(note) ? DBNull.Value : note.Trim() },
                new("p_from_session",   NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(fromSession) ? DBNull.Value : fromSession.Trim() },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "opening_due_cursor" }
            };
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_import_opening_due", p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "No response.");
                var row = ds.Tables[0].Rows[0];
                return (Convert.ToBoolean(row["success"]), row["message"]?.ToString() ?? string.Empty);
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Opening due refused (SqlState {SqlState}) for {AdmissionNo}", ex.SqlState, admissionNo);
                return (false, ex.MessageText);
            }
        }
    }
}
