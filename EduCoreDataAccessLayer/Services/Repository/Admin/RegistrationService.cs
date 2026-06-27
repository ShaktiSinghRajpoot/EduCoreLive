using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class RegistrationService : IRegistrationService
    {
        private readonly PgExec _db;
        private const string SpManage = "core.sp_registration_manage";

        // WHY: log the real cause before catch blocks swallow it into a friendly message.
        private readonly ILogger<RegistrationService> _logger;

        public RegistrationService(PgExec db, ILogger<RegistrationService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<(List<RegistrationListItem> Items, int TotalCount)> GetRegistrationsAsync(
            int tenantId, int schoolId, int actionUserId,
            int pageNumber = 1, int pageSize = 10,
            string? search = null, string? session = null,
            string? className = null, string? feeStatus = null)
        {
            var items = new List<RegistrationListItem>();
            if (tenantId <= 1 || schoolId <= 0) return (items, 0);

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "List" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_search",         NpgsqlDbType.Text)    { Value = (object?)search    ?? DBNull.Value },
                new("p_session",        NpgsqlDbType.Text)    { Value = (object?)session   ?? DBNull.Value },
                new("p_class",          NpgsqlDbType.Text)    { Value = (object?)className ?? DBNull.Value },
                new("p_fee_status",     NpgsqlDbType.Text)    { Value = (object?)feeStatus ?? DBNull.Value },
                new("p_reason",         NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_page",           NpgsqlDbType.Integer) { Value = pageNumber },
                new("p_page_size",      NpgsqlDbType.Integer) { Value = pageSize },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            int total = 0;
            var dal = _db;
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpManage, parameters);

            if (ds.Tables.Count > 0)
            {
                foreach (DataRow row in ds.Tables[0].Rows)
                {
                    items.Add(new RegistrationListItem
                    {
                        EnquiryId           = IntVal(row, "enquiry_id"),
                        RegistrationNumber  = NullStr(row, "registration_number"),
                        RegistrationDate    = DateVal(row, "registration_date"),
                        RegistrationFeePaid = BoolVal(row, "registration_fee_paid"),
                        StudentName         = Str(row, "student_name"),
                        ClassName           = NullStr(row, "class_name"),
                        Session             = NullStr(row, "session"),
                        ParentName          = NullStr(row, "parent_name"),
                        Mobile              = NullStr(row, "mobile"),
                        Status              = Str(row, "status"),
                        AdmissionId         = Has(row, "admission_id") && row["admission_id"] != DBNull.Value
                                                ? Convert.ToInt32(row["admission_id"]) : null
                    });
                    if (total == 0) total = IntVal(row, "total_count");
                }
            }

            return (items, total);
        }

        public async Task<RegistrationStats> GetStatsAsync(int tenantId, int schoolId, int actionUserId)
        {
            var stats = new RegistrationStats();
            if (tenantId <= 1 || schoolId <= 0) return stats;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "Stats" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            var dal = _db;
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpManage, parameters);

            if (ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0)
            {
                var row = ds.Tables[0].Rows[0];
                stats.TotalRegistered = IntVal(row, "total_registered");
                stats.FeeCollected    = IntVal(row, "fee_collected");
                stats.FeePending      = IntVal(row, "fee_pending");
                stats.Converted       = IntVal(row, "converted");
            }

            return stats;
        }

        public Task<(int Success, string Message)> CancelRegistrationAsync(
            int enquiryId, string? reason, int tenantId, int schoolId, int actionUserId)
            => RunActionAsync("Cancel", enquiryId, reason, tenantId, schoolId, actionUserId);

        public Task<(int Success, string Message)> MarkFeePaidAsync(
            int enquiryId, int tenantId, int schoolId, int actionUserId)
            => RunActionAsync("MarkFeePaid", enquiryId, null, tenantId, schoolId, actionUserId);

        // ── Shared action runner (Cancel / MarkFeePaid) ─────────────
        private async Task<(int Success, string Message)> RunActionAsync(
            string operation, int enquiryId, string? reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0)
                return (0, "Invalid request.");

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
                new("p_reason",         NpgsqlDbType.Text)    { Value = (object?)reason ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                var dal = _db;
                var ds = await dal.ExecuteProcedureWithCursorsAsync(SpManage, parameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (0, "No response.");

                var row     = ds.Tables[0].Rows[0];
                int success = row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]) ? 1 : 0;
                string msg  = Has(row, "message") && row["message"] != DBNull.Value
                                ? row["message"].ToString()! : (success > 0 ? "Done." : "Error.");
                return (success, msg);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Registration action '{Operation}' rejected for enquiry {EnquiryId}, school {SchoolId}. SqlState {SqlState}", operation, enquiryId, schoolId, pex.SqlState);
                return (0, pex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error in registration action '{Operation}' for enquiry {EnquiryId}, school {SchoolId}.", operation, enquiryId, schoolId);
                return (0, "Unable to complete the action.");
            }
        }

        // ── helpers ─────────────────────────────────────────────────
        private static bool      Has(DataRow r, string c)     => r.Table.Columns.Contains(c);
        private static int       IntVal(DataRow r, string c)  => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static bool      BoolVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);
        private static string    Str(DataRow r, string c)     => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string?   NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
        private static DateOnly? DateVal(DataRow r, string c)
        {
            if (!Has(r, c) || r[c] == DBNull.Value) return null;
            var v = r[c];
            // Npgsql maps a Postgres `date` column to DateOnly; handle both forms.
            if (v is DateOnly d) return d;
            if (v is DateTime dt) return DateOnly.FromDateTime(dt);
            return DateOnly.TryParse(v.ToString(), out var p) ? p : null;
        }
    }
}
