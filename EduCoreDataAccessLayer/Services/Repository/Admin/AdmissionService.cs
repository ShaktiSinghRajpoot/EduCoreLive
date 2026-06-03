using System.Data;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class AdmissionService : IAdmissionService
    {
        private readonly string _connectionString;
        private const string SpMain = "core.sp_admission_manage";

        public AdmissionService(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
        }

        // ── Save admission ───────────────────────────────────────
        public async Task<AdmissionSaveResult> SaveAdmissionAsync(
            AdmissionModel model, int tenantId, int schoolId, int actionUserId,
            decimal concessionCap = 100000m)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new AdmissionSaveResult { Success = false, Message = "Invalid tenant/school context." };

            // Normalise the fee plan to the JSON shape the SP expects.
            string feePlanJson = JsonSerializer.Serialize(
                (model.FeePlan ?? new List<StudentFeePlanItem>()).Select(f => new
                {
                    feeHeadId   = f.FeeHeadId,
                    feeHeadName = f.FeeHeadName,
                    frequency   = f.Frequency,
                    amount      = f.Amount,
                    isOptional  = f.IsOptional
                }));

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",        NpgsqlDbType.Text)    { Value = "SaveAdmission" },
                new("p_tenant_id",        NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",        NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",   NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",       NpgsqlDbType.Integer) { Value = model.StudentId > 0 ? model.StudentId : DBNull.Value },
                new("p_admission_no",     NpgsqlDbType.Text)    { Value = (object?)model.AdmissionNo      ?? DBNull.Value },
                new("p_roll_no",          NpgsqlDbType.Text)    { Value = (object?)model.RollNo           ?? DBNull.Value },
                new("p_student_name",     NpgsqlDbType.Text)    { Value = model.StudentName },
                new("p_gender",           NpgsqlDbType.Text)    { Value = (object?)model.Gender           ?? DBNull.Value },
                new("p_dob",              NpgsqlDbType.Date)    { Value = (object?)model.DateOfBirth      ?? DBNull.Value },
                new("p_class_name",       NpgsqlDbType.Text)    { Value = model.ClassName },
                new("p_section",          NpgsqlDbType.Text)    { Value = (object?)model.Section          ?? DBNull.Value },
                new("p_academic_year",    NpgsqlDbType.Text)    { Value = model.AcademicYear },
                new("p_admission_date",   NpgsqlDbType.Date)    { Value = (object?)model.AdmissionDate    ?? DBNull.Value },
                new("p_guardian_name",    NpgsqlDbType.Text)    { Value = (object?)model.GuardianName     ?? DBNull.Value },
                new("p_mother_name",      NpgsqlDbType.Text)    { Value = (object?)model.MotherName       ?? DBNull.Value },
                new("p_mobile",           NpgsqlDbType.Text)    { Value = (object?)model.MobileNumber     ?? DBNull.Value },
                new("p_alt_mobile",       NpgsqlDbType.Text)    { Value = (object?)model.AlternateMobile  ?? DBNull.Value },
                new("p_address",          NpgsqlDbType.Text)    { Value = (object?)model.Address          ?? DBNull.Value },
                new("p_pay_today_total",  NpgsqlDbType.Numeric) { Value = model.PayTodayTotal },
                new("p_monthly_total",    NpgsqlDbType.Numeric) { Value = model.MonthlyTotal },
                new("p_yearly_total",     NpgsqlDbType.Numeric) { Value = model.YearlyTotal },
                new("p_annual_total",     NpgsqlDbType.Numeric) { Value = model.AnnualTotal },
                new("p_concession_type",  NpgsqlDbType.Text)    { Value = (object?)model.ConcessionType   ?? DBNull.Value },
                new("p_concession_value", NpgsqlDbType.Numeric) { Value = model.ConcessionValue },
                new("p_concession_amount",NpgsqlDbType.Numeric) { Value = model.ConcessionAmount },
                new("p_concession_reason",NpgsqlDbType.Text)    { Value = (object?)model.ConcessionReason ?? DBNull.Value },
                new("p_concession_cap",   NpgsqlDbType.Numeric) { Value = concessionCap },
                new("p_fee_plan_json",    NpgsqlDbType.Jsonb)   { Value = feePlanJson },
                new("p_enquiry_id",       NpgsqlDbType.Integer) { Value = (object?)model.EnquiryId        ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "save_admission_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                return new AdmissionSaveResult { Success = false, Message = "No response from server." };

            var row = ds.Tables[0].Rows[0];
            return new AdmissionSaveResult
            {
                StudentId   = IntVal(row, "student_id"),
                Success     = IntVal(row, "success") > 0,
                Message     = NullStr(row, "message") ?? string.Empty,
                AdmissionNo = NullStr(row, "admission_no")
            };
        }

        // ── List ─────────────────────────────────────────────────
        public async Task<(List<StudentListModel> Items, int TotalCount)> GetStudentsAsync(
            int tenantId, int schoolId, int actionUserId,
            int pageNumber = 1, int pageSize = 10,
            string? search = null, string? filterClass = null, string? filterSection = null,
            string? filterGender = null, string? filterYear = null, string? filterStatus = null)
        {
            var list = new List<StudentListModel>();
            if (tenantId <= 1 || schoolId <= 0) return (list, 0);

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "GetStudents" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_page_number",    NpgsqlDbType.Integer) { Value = pageNumber },
                new("p_page_size",      NpgsqlDbType.Integer) { Value = pageSize },
                new("p_search",         NpgsqlDbType.Text)    { Value = (object?)search        ?? DBNull.Value },
                new("p_filter_class",   NpgsqlDbType.Text)    { Value = (object?)filterClass   ?? DBNull.Value },
                new("p_filter_section", NpgsqlDbType.Text)    { Value = (object?)filterSection ?? DBNull.Value },
                new("p_filter_gender",  NpgsqlDbType.Text)    { Value = (object?)filterGender  ?? DBNull.Value },
                new("p_filter_year",    NpgsqlDbType.Text)    { Value = (object?)filterYear    ?? DBNull.Value },
                new("p_filter_status",  NpgsqlDbType.Text)    { Value = (object?)filterStatus  ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "students_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return (list, 0);

            int totalCount = 0;
            foreach (DataRow row in ds.Tables[0].Rows)
            {
                if (totalCount == 0 && row.Table.Columns.Contains("total_count"))
                    totalCount = IntVal(row, "total_count");
                list.Add(MapListRow(row));
            }
            return (list, totalCount);
        }

        // ── Single ───────────────────────────────────────────────
        public async Task<AdmissionModel?> GetStudentByIdAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return null;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "GetStudentById" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_by_id_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var row = ds.Tables[0].Rows[0];
            return new AdmissionModel
            {
                StudentId        = IntVal(row, "student_id"),
                TenantId         = tenantId,
                SchoolId         = schoolId,
                AdmissionNo      = NullStr(row, "admission_no"),
                RollNo           = NullStr(row, "roll_no"),
                StudentName      = Str(row, "student_name"),
                Gender           = NullStr(row, "gender"),
                DateOfBirth      = DateVal(row, "dob"),
                ClassName        = Str(row, "class_name"),
                Section          = NullStr(row, "section"),
                AcademicYear     = Str(row, "academic_year"),
                AdmissionDate    = DateVal(row, "admission_date"),
                GuardianName     = NullStr(row, "guardian_name"),
                MotherName       = NullStr(row, "mother_name"),
                MobileNumber     = NullStr(row, "mobile"),
                AlternateMobile  = NullStr(row, "alt_mobile"),
                Address          = NullStr(row, "address"),
                PayTodayTotal    = DecVal(row, "pay_today_total"),
                MonthlyTotal     = DecVal(row, "monthly_total"),
                YearlyTotal      = DecVal(row, "yearly_total"),
                AnnualTotal      = DecVal(row, "annual_total"),
                ConcessionType   = NullStr(row, "concession_type"),
                ConcessionValue  = DecVal(row, "concession_value"),
                ConcessionAmount = DecVal(row, "concession_amount"),
                ConcessionReason = NullStr(row, "concession_reason"),
                EnquiryId        = Has(row, "enquiry_id") && row["enquiry_id"] != DBNull.Value
                                     ? Convert.ToInt32(row["enquiry_id"]) : null
            };
        }

        // ── Delete (soft) ────────────────────────────────────────
        public async Task<int> DeleteStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return 0;

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Text)    { Value = "DeleteStudent" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "delete_student_cursor" }
            };

            using var dal = new PostgreSqlDal(_connectionString);
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);
            return ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0 ? 1 : 0;
        }

        // ── Mapper ───────────────────────────────────────────────
        private static StudentListModel MapListRow(DataRow row) => new()
        {
            StudentId      = IntVal(row, "student_id"),
            AdmissionNo    = Str(row, "admission_no"),
            RollNo         = NullStr(row, "roll_no"),
            StudentName    = Str(row, "student_name"),
            Gender         = NullStr(row, "gender"),
            ClassName      = Str(row, "class_name"),
            Section        = NullStr(row, "section"),
            AcademicYear   = Str(row, "academic_year"),
            AdmissionDate  = DateVal(row, "admission_date"),
            GuardianName   = NullStr(row, "guardian_name"),
            Mobile         = NullStr(row, "mobile"),
            AnnualTotal    = DecVal(row, "annual_total"),
            Status         = Has(row, "status") && row["status"] != DBNull.Value ? row["status"].ToString()! : "Active",
            ApprovalStatus = Has(row, "approval_status") && row["approval_status"] != DBNull.Value ? row["approval_status"].ToString()! : "Approved",
            FeeStatus      = Has(row, "fee_status") && row["fee_status"] != DBNull.Value ? row["fee_status"].ToString()! : "Pending",
            FeeDue         = DecVal(row, "fee_due"),
            EnquiryId      = Has(row, "enquiry_id") && row["enquiry_id"] != DBNull.Value ? Convert.ToInt32(row["enquiry_id"]) : null
        };

        // ── Tiny helpers (same style as EnquiryService) ──────────
        private static bool      Has(DataRow r, string col)     => r.Table.Columns.Contains(col);
        private static int       IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static decimal   DecVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : 0m;
        private static string    Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string?   NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
        private static DateOnly? DateVal(DataRow r, string col)
        {
            if (!Has(r, col) || r[col] == DBNull.Value)
                return null;

            var value = r[col];

            if (value is DateOnly d)
                return d;

            if (value is DateTime dt)
                return DateOnly.FromDateTime(dt);

            if (value is string s && DateTime.TryParse(s, out var parsed))
                return DateOnly.FromDateTime(parsed);

            throw new InvalidCastException($"Unsupported date type: {value.GetType()}");
        }
    }
}
