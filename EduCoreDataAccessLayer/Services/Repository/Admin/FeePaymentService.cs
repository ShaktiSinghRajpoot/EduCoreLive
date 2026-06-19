using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
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
        private const string SpRegistrationRecord = "core.sp_registration_fee_record";
        private const string SpStudentDues = "core.sp_student_dues_get";

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

        public async Task<(bool Success, string Message, string? ReceiptNo)> RecordRegistrationPaymentAsync(
            int enquiryId, decimal amount, string paymentMode, string? referenceNo,
            string? remarks, string? finYear, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || enquiryId <= 0)
                return (false, "Invalid request.", null);
            if (amount <= 0)
                return (false, "Payment amount must be greater than zero.", null);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_enquiry_id",     NpgsqlDbType.Integer) { Value = enquiryId },
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
                var ds = await dal.ExecuteProcedureWithCursorsAsync(SpRegistrationRecord, parameters);

                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "No response.", null);

                var row     = ds.Tables[0].Rows[0];
                bool ok     = row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]);
                string msg  = row.Table.Columns.Contains("message") && row["message"] != DBNull.Value
                                ? row["message"].ToString()! : (ok ? "Registration fee recorded." : "Error.");
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
                return (false, "Unable to record the registration fee.", null);
            }
        }

        public async Task<List<StudentDueItem>> GetStudentDuesAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<StudentDueItem>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return list;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "result_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpStudentDues, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new StudentDueItem
                {
                    LedgerId         = row["ledger_id"] == DBNull.Value ? 0 : Convert.ToInt32(row["ledger_id"]),
                    FeeHeadName      = row["fee_head_name"] == DBNull.Value ? string.Empty : row["fee_head_name"].ToString()!,
                    Frequency        = row["frequency"] == DBNull.Value ? string.Empty : row["frequency"].ToString()!,
                    InstallmentLabel = row["installment_label"] == DBNull.Value ? null : row["installment_label"].ToString(),
                    DueDate          = DueDate(row["due_date"]),
                    AmountDue        = row["amount_due"] == DBNull.Value ? 0 : Convert.ToDecimal(row["amount_due"]),
                    AmountPaid       = row["amount_paid"] == DBNull.Value ? 0 : Convert.ToDecimal(row["amount_paid"]),
                    Outstanding      = row["outstanding"] == DBNull.Value ? 0 : Convert.ToDecimal(row["outstanding"])
                });
            }

            return list;
        }

        private static DateOnly? DueDate(object v)
        {
            if (v == DBNull.Value) return null;
            if (v is DateOnly d) return d;
            if (v is DateTime dt) return DateOnly.FromDateTime(dt);
            return DateOnly.TryParse(v.ToString(), out var p) ? p : null;
        }
    }
}
