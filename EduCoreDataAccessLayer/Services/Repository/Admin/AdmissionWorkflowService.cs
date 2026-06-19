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
    public class AdmissionWorkflowService : IAdmissionWorkflowService
    {
        private readonly string _connectionString;
        private readonly ILogger<AdmissionWorkflowService>? _logger;
        private const string SpAdmissionWorkflowManage = "core.sp_school_admin_admission_workflow_manage";

        public AdmissionWorkflowService(IConfiguration configuration, ILogger<AdmissionWorkflowService>? logger = null)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
            _logger = logger;
        }

        public async Task<AdmissionWorkflowModel> GetAdmissionWorkflowAsync(int tenantId, int schoolId, int actionUserId)
        {
            // Always hand the screen a usable model. A school that has never saved
            // workflow settings (or a backend where the SP isn't deployed yet) gets
            // the safe defaults: direct-admission, no registration.
            var model = new AdmissionWorkflowModel { TenantId = tenantId, SchoolId = schoolId };

            if (tenantId <= 1 || schoolId <= 0)
                return model;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "GetAdmissionWorkflow"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_enable_registration", DBNull.Value),
                new NpgsqlParameter("p_registration_required_before_admission", DBNull.Value),
                new NpgsqlParameter("p_enable_registration_fee", DBNull.Value),
                new NpgsqlParameter("p_auto_generate_registration_number", DBNull.Value),
                new NpgsqlParameter("p_registration_number_prefix", DBNull.Value),
                new NpgsqlParameter("p_collect_fee_at_admission", DBNull.Value),
                new NpgsqlParameter("p_enable_security_fee", DBNull.Value),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                using var dal = new PostgreSqlDal(_connectionString);
                var ds = await dal.ExecuteProcedureWithCursorsAsync(SpAdmissionWorkflowManage, parameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return model;

                var row = ds.Tables[0].Rows[0];

                model.EnableRegistration = GetBool(row, "enable_registration");
                model.RegistrationRequiredBeforeAdmission = GetBool(row, "registration_required_before_admission");
                model.EnableRegistrationFee = GetBool(row, "enable_registration_fee");
                model.AutoGenerateRegistrationNumber = GetBool(row, "auto_generate_registration_number", true);
                model.CollectFeeAtAdmission = GetBool(row, "collect_fee_at_admission");
                model.EnableSecurityFee = GetBool(row, "enable_security_fee");

                if (row.Table.Columns.Contains("registration_number_prefix") && row["registration_number_prefix"] != DBNull.Value)
                    model.RegistrationNumberPrefix = row["registration_number_prefix"].ToString() ?? "REG-";
            }
            catch (Exception ex)
            {
                // Backend not provisioned yet — fall back to defaults so the
                // settings screen still renders and can be saved later. Log it so a
                // genuinely broken backend doesn't silently masquerade as "no settings".
                _logger?.LogWarning(ex, "GetAdmissionWorkflow failed for tenant {Tenant}/school {School}; returning defaults.", tenantId, schoolId);
                return model;
            }

            return model;
        }

        public async Task<int> SaveAdmissionWorkflowAsync(AdmissionWorkflowModel model, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return 0;

            model.TenantId = tenantId;
            model.SchoolId = schoolId;

            // Dependent flags collapse to FALSE when their parent toggle is off,
            // so an invalid combination can never reach the database.
            bool enableReg = model.EnableRegistration;
            bool required = enableReg && model.RegistrationRequiredBeforeAdmission;
            bool enableFee = enableReg && model.EnableRegistrationFee;
            string prefix = string.IsNullOrWhiteSpace(model.RegistrationNumberPrefix)
                ? "REG-"
                : model.RegistrationNumberPrefix.Trim();
            bool enableSec = model.EnableSecurityFee;

            var parameters = new NpgsqlParameter[]
            {
                new NpgsqlParameter("p_operation", "SaveAdmissionWorkflow"),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_enable_registration", enableReg),
                new NpgsqlParameter("p_registration_required_before_admission", required),
                new NpgsqlParameter("p_enable_registration_fee", enableFee),
                new NpgsqlParameter("p_auto_generate_registration_number", model.AutoGenerateRegistrationNumber),
                new NpgsqlParameter("p_registration_number_prefix", prefix),
                new NpgsqlParameter("p_collect_fee_at_admission", model.CollectFeeAtAdmission),
                new NpgsqlParameter("p_enable_security_fee", enableSec),
                new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "admission_workflow_save_cursor" }
            };

            try
            {
                using var dal = new PostgreSqlDal(_connectionString);
                var ds = await dal.ExecuteProcedureWithCursorsAsync(SpAdmissionWorkflowManage, parameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return 0;

                var row = ds.Tables[0].Rows[0];
                return row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]) ? 1 : 0;
            }
            catch (Exception ex)
            {
                // Stored procedure not deployed yet — report a clean failure to the
                // UI instead of surfacing a 500. Logged so a real save failure is
                // visible rather than silently reported as "unable to save".
                _logger?.LogError(ex, "SaveAdmissionWorkflow failed for tenant {Tenant}/school {School}.", tenantId, schoolId);
                return 0;
            }
        }

        private static bool GetBool(DataRow row, string column, bool fallback = false)
        {
            if (!row.Table.Columns.Contains(column) || row[column] == DBNull.Value)
                return fallback;
            return Convert.ToBoolean(row[column]);
        }
    }
}
