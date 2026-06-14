using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class FeePaymentService : IFeePaymentService
    {
        private readonly string _connectionString;
        private const string SpRecord = "core.sp_fee_payment_record";

        public FeePaymentService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        public async Task<(bool Success, string Message, string? ReceiptNo)> RecordPaymentAsync(
            int studentId, decimal amount, string paymentMode, string? referenceNo,
            string? remarks, string? finYear, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return (false, "Invalid request.", null);
            if (amount <= 0)
                return (false, "Payment amount must be greater than zero.", null);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_amount",         NpgsqlDbType.Numeric) { Value = amount },
                new("p_payment_mode",   NpgsqlDbType.Text)    { Value = string.IsNullOrWhiteSpace(paymentMode) ? "Cash" : paymentMode },
                new("p_reference_no",   NpgsqlDbType.Text)    { Value = (object?)referenceNo ?? DBNull.Value },
                new("p_remarks",        NpgsqlDbType.Text)    { Value = (object?)remarks ?? DBNull.Value },
                new("p_payment_date",   NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_fin_year",       NpgsqlDbType.Text)    { Value = (object?)finYear ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            try
            {
                using var dal = new PostgreSqlDal(_connectionString);
                var ds = await dal.ExecuteProcedureWithCursorsAsync(SpRecord, parameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "No response.", null);

                var row     = ds.Tables[0].Rows[0];
                bool ok     = row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]);
                string msg  = row.Table.Columns.Contains("message") && row["message"] != DBNull.Value
                                ? row["message"].ToString()! : (ok ? "Payment recorded." : "Error.");
                string? rcp = row.Table.Columns.Contains("receipt_no") && row["receipt_no"] != DBNull.Value
                                ? row["receipt_no"].ToString() : null;
                return (ok, msg, rcp);
            }
            catch (PostgresException pex)
            {
                return (false, pex.MessageText, null);
            }
            catch
            {
                return (false, "Unable to record the payment.", null);
            }
        }
    }
}
