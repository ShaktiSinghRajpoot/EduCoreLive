using System.Data;
using EduCoreDataAccessLayer.Helpers;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class AdmissionService : IAdmissionService
    {
        private readonly PgExec _db;
        private readonly ILogger<AdmissionService> _logger;
        private const string SpMain = "core.sp_admission_manage";
        private const string SpStudentList = "core.sp_student_list";
        private const string SpStudentExit = "core.sp_student_exit";
        private const string SpStudentExitList = "core.sp_student_exit_list";
        private const string SpClassLadder = "core.sp_class_ladder";
        private const string SpPromotionHistory = "core.sp_promotion_history";
        private const string SpStudentPromote = "core.sp_student_promote";
        private const string SpEnrolmentHistory = "core.sp_student_enrolment_history";

        public AdmissionService(PgExec db, ILogger<AdmissionService> logger)
        {
            _db = db;
            _logger = logger;
        }

        // ── Save admission ───────────────────────────────────────
        public async Task<AdmissionSaveResult> SaveAdmissionAsync(AdmissionModel model, int tenantId, int schoolId, int actionUserId, decimal concessionCap = 100000m)
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
                new("p_dob",              NpgsqlDbType.Unknown)    { Value = (object?)model.DateOfBirth      ?? DBNull.Value },
                new("p_class_name",       NpgsqlDbType.Text)    { Value = model.ClassName },
                new("p_section",          NpgsqlDbType.Text)    { Value = (object?)model.Section          ?? DBNull.Value },
                new("p_academic_year",    NpgsqlDbType.Text)    { Value = model.AcademicYear },
                new("p_admission_date",   NpgsqlDbType.Unknown)    { Value = (object?)model.AdmissionDate    ?? DBNull.Value },
                new("p_guardian_name",    NpgsqlDbType.Text)    { Value = (object?)model.GuardianName     ?? DBNull.Value },
                new("p_mother_name",      NpgsqlDbType.Text)    { Value = (object?)model.MotherName       ?? DBNull.Value },
                new("p_mobile",           NpgsqlDbType.Text)    { Value = (object?)model.MobileNumber     ?? DBNull.Value },
                new("p_alt_mobile",       NpgsqlDbType.Text)    { Value = (object?)model.AlternateMobile  ?? DBNull.Value },
                new("p_address",          NpgsqlDbType.Text)    { Value = (object?)model.Address          ?? DBNull.Value },
                new("p_blood_group",          NpgsqlDbType.Text)    { Value = (object?)model.BloodGroup          ?? DBNull.Value },
                new("p_religion",             NpgsqlDbType.Text)    { Value = (object?)model.Religion            ?? DBNull.Value },
                new("p_category",             NpgsqlDbType.Text)    { Value = (object?)model.Category            ?? DBNull.Value },
                new("p_nationality",          NpgsqlDbType.Text)    { Value = (object?)model.Nationality         ?? DBNull.Value },
                new("p_mother_tongue",        NpgsqlDbType.Text)    { Value = (object?)model.MotherTongue        ?? DBNull.Value },
                new("p_id_proof_no",          NpgsqlDbType.Text)    { Value = (object?)model.IdProofNo           ?? DBNull.Value },
                new("p_apaar_id",             NpgsqlDbType.Text)    { Value = (object?)model.ApaarId             ?? DBNull.Value },
                new("p_udise_student_id",     NpgsqlDbType.Text)    { Value = (object?)model.UdiseStudentId      ?? DBNull.Value },
                new("p_prev_school_name",     NpgsqlDbType.Text)    { Value = (object?)model.PrevSchoolName       ?? DBNull.Value },
                new("p_prev_board",           NpgsqlDbType.Text)    { Value = (object?)model.PrevBoard            ?? DBNull.Value },
                new("p_prev_class",           NpgsqlDbType.Text)    { Value = (object?)model.PrevClass            ?? DBNull.Value },
                new("p_prev_tc_no",           NpgsqlDbType.Text)    { Value = (object?)model.PrevTcNo             ?? DBNull.Value },
                new("p_father_occupation",    NpgsqlDbType.Text)    { Value = (object?)model.FatherOccupation     ?? DBNull.Value },
                new("p_father_qualification", NpgsqlDbType.Text)    { Value = (object?)model.FatherQualification  ?? DBNull.Value },
                new("p_father_email",         NpgsqlDbType.Text)    { Value = (object?)model.FatherEmail          ?? DBNull.Value },
                new("p_mother_occupation",    NpgsqlDbType.Text)    { Value = (object?)model.MotherOccupation     ?? DBNull.Value },
                new("p_mother_qualification", NpgsqlDbType.Text)    { Value = (object?)model.MotherQualification  ?? DBNull.Value },
                new("p_mother_email",         NpgsqlDbType.Text)    { Value = (object?)model.MotherEmail          ?? DBNull.Value },
                new("p_annual_income",        NpgsqlDbType.Numeric) { Value = (object?)model.AnnualIncome         ?? DBNull.Value },
                new("p_documents",            NpgsqlDbType.Jsonb)   { Value = (object?)model.DocumentsJson        ?? DBNull.Value },
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

            var dal = _db;
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

            var dal = _db;
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

        // ── Fat-model list page (server-side paging + sorting) ────
        public async Task<StudentListModel> GetStudentListPageAsync(
            StudentListModel query, int tenantId, int schoolId, int actionUserId)
        {
            query.Items = new List<StudentListModel>();
            if (tenantId <= 1 || schoolId <= 0) { query.TotalCount = 0; return query; }

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_search",         NpgsqlDbType.Text)    { Value = (object?)query.Search       ?? DBNull.Value },
                new("p_filter_class",   NpgsqlDbType.Text)    { Value = (object?)query.FilterClass  ?? DBNull.Value },
                new("p_filter_gender",  NpgsqlDbType.Text)    { Value = (object?)query.FilterGender ?? DBNull.Value },
                new("p_filter_fee",     NpgsqlDbType.Text)    { Value = (object?)query.FilterFee    ?? DBNull.Value },
                new("p_filter_year",    NpgsqlDbType.Text)    { Value = (object?)query.FilterYear   ?? DBNull.Value },
                new("p_filter_status",  NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_page_no",        NpgsqlDbType.Integer) { Value = query.Page },
                new("p_page_size",      NpgsqlDbType.Integer) { Value = query.PageSize },
                new("p_sort_column",    NpgsqlDbType.Text)    { Value = (object?)query.SortColumn   ?? DBNull.Value },
                new("p_sort_dir",       NpgsqlDbType.Text)    { Value = query.SortDirection },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_list_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpStudentList, parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) { query.TotalCount = 0; return query; }

            var first = ds.Tables[0].Rows[0];
            query.TotalCount  = IntVal(first, "total_count");
            query.MaleCount   = IntVal(first, "male_count");
            query.FemaleCount = IntVal(first, "female_count");
            query.ActiveCount = IntVal(first, "active_count");

            foreach (DataRow row in ds.Tables[0].Rows)
                query.Items.Add(MapListRow(row));

            return query;
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

            var dal = _db;
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
                DateOfBirth      = DbRead.NStr(row, "dob"),
                ClassName        = Str(row, "class_name"),
                Section          = NullStr(row, "section"),
                AcademicYear     = Str(row, "academic_year"),
                AdmissionDate    = DbRead.NStr(row, "admission_date"),
                GuardianName     = NullStr(row, "guardian_name"),
                MotherName       = NullStr(row, "mother_name"),
                MobileNumber     = NullStr(row, "mobile"),
                AlternateMobile  = NullStr(row, "alt_mobile"),
                Address          = NullStr(row, "address"),

                // The proc selects s.*, so these were available all along — the
                // mapper simply never read them, which is why Edit Student could
                // not show a student's blood group, category or previous school.
                BloodGroup       = NullStr(row, "blood_group"),
                Religion         = NullStr(row, "religion"),
                Category         = NullStr(row, "category"),
                Nationality      = NullStr(row, "nationality"),
                MotherTongue     = NullStr(row, "mother_tongue"),
                IdProofNo        = NullStr(row, "id_proof_no"),
                ApaarId          = NullStr(row, "apaar_id"),
                UdiseStudentId   = NullStr(row, "udise_student_id"),
                PrevSchoolName   = NullStr(row, "prev_school_name"),
                PrevBoard        = NullStr(row, "prev_board"),
                PrevClass        = NullStr(row, "prev_class"),
                PrevTcNo         = NullStr(row, "prev_tc_no"),

                // Parent details were saved at admission but never read back, so the
                // dashboard showed "—" and Edit could not change them.
                FatherOccupation     = NullStr(row, "father_occupation"),
                FatherQualification  = NullStr(row, "father_qualification"),
                FatherEmail          = NullStr(row, "father_email"),
                MotherOccupation     = NullStr(row, "mother_occupation"),
                MotherQualification  = NullStr(row, "mother_qualification"),
                MotherEmail          = NullStr(row, "mother_email"),
                AnnualIncome         = Has(row, "annual_income") && row["annual_income"] != DBNull.Value
                                         ? Convert.ToDecimal(row["annual_income"]) : null,

                PayTodayTotal    = DecVal(row, "pay_today_total"),
                MonthlyTotal     = DecVal(row, "monthly_total"),
                YearlyTotal      = DecVal(row, "yearly_total"),
                AnnualTotal      = DecVal(row, "annual_total"),
                ConcessionType   = NullStr(row, "concession_type"),
                ConcessionValue  = DecVal(row, "concession_value"),
                ConcessionAmount = DecVal(row, "concession_amount"),
                ConcessionReason = NullStr(row, "concession_reason"),
                EnquiryId        = Has(row, "enquiry_id") && row["enquiry_id"] != DBNull.Value
                                     ? Convert.ToInt32(row["enquiry_id"]) : null,
                IsActive         = !Has(row, "is_active") || row["is_active"] == DBNull.Value || Convert.ToBoolean(row["is_active"]),
                Status           = NullStr(row, "status"),
                DateOfLeaving    = DbRead.NStr(row, "date_of_leaving"),
                LeavingReason    = NullStr(row, "leaving_reason"),
                PhotoUrl         = NullStr(row, "photo_url")
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

            var dal = _db;
            var ds = await dal.ExecuteProcedureWithCursorsAsync(SpMain, parameters);
            return ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0 ? 1 : 0;
        }

        // ── Student exit ─────────────────────────────────────────
        // A student who leaves keeps their record (ledger, receipts and the TC
        // register all point at the same student_id); only is_active/status change.
        public async Task<StudentExitResult> ExitStudentAsync(
            StudentExitRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || request.StudentId <= 0)
                return new StudentExitResult { Message = "Invalid student context." };

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",       NpgsqlDbType.Text)    { Value = "Exit" },
                new("p_tenant_id",       NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",       NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",  NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",      NpgsqlDbType.Integer) { Value = request.StudentId },
                new("p_status",          NpgsqlDbType.Text)    { Value = (object?)request.Status ?? DBNull.Value },
                new("p_date_of_leaving", NpgsqlDbType.Unknown)    { Value = (object?)request.DateOfLeaving ?? DBNull.Value },
                new("p_reason",          NpgsqlDbType.Text)    { Value = (object?)request.Reason ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_exit_cursor" }
            };

            return await RunExitAsync(parameters);
        }

        public async Task<StudentExitResult> UndoStudentExitAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return new StudentExitResult { Message = "Invalid student context." };

            var parameters = new NpgsqlParameter[]
            {
                new("p_operation",       NpgsqlDbType.Text)    { Value = "Undo" },
                new("p_tenant_id",       NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",       NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",  NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",      NpgsqlDbType.Integer) { Value = studentId },
                new("p_status",          NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_date_of_leaving", NpgsqlDbType.Unknown)    { Value = DBNull.Value },
                new("p_reason",          NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_exit_cursor" }
            };

            return await RunExitAsync(parameters);
        }

        // The proc RAISEs its business rules ("already left", "date required"),
        // so the message the office sees comes straight from there.
        private async Task<StudentExitResult> RunExitAsync(NpgsqlParameter[] parameters)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpStudentExit, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new StudentExitResult { Message = "Nothing was changed." };

                var row = ds.Tables[0].Rows[0];
                return new StudentExitResult
                {
                    Success     = true,
                    Message     = Str(row, "message"),
                    Outstanding = DecVal(row, "outstanding")
                };
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Student exit/reactivate rejected. SqlState {SqlState}", ex.SqlState);
                return new StudentExitResult { Message = ex.MessageText };
            }
        }

        public async Task<StudentExitListModel> GetStudentExitListAsync(
            StudentExitListModel query, int tenantId, int schoolId, int actionUserId)
        {
            query.Items = new List<StudentExitListModel>();
            if (tenantId <= 1 || schoolId <= 0) { query.TotalCount = 0; return query; }

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_search",         NpgsqlDbType.Text)    { Value = (object?)query.Search       ?? DBNull.Value },
                new("p_filter_status",  NpgsqlDbType.Text)    { Value = (object?)query.FilterStatus ?? DBNull.Value },
                new("p_filter_dues",    NpgsqlDbType.Text)    { Value = (object?)query.FilterDues   ?? DBNull.Value },
                new("p_page_no",        NpgsqlDbType.Integer) { Value = query.Page },
                new("p_page_size",      NpgsqlDbType.Integer) { Value = query.PageSize },
                new("p_sort_column",    NpgsqlDbType.Text)    { Value = (object?)query.SortColumn   ?? DBNull.Value },
                new("p_sort_dir",       NpgsqlDbType.Text)    { Value = query.SortDirection },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_exit_list_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpStudentExitList, parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) { query.TotalCount = 0; return query; }

            var first = ds.Tables[0].Rows[0];
            query.TotalCount    = IntVal(first, "total_count");
            query.TransferCount = IntVal(first, "transfer_count");
            query.PassoutCount  = IntVal(first, "passout_count");
            query.DuesCount     = IntVal(first, "dues_count");

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                query.Items.Add(new StudentExitListModel
                {
                    StudentId     = IntVal(row, "student_id"),
                    AdmissionNo   = NullStr(row, "admission_no"),
                    StudentName   = Str(row, "student_name"),
                    ClassName     = NullStr(row, "class_name"),
                    Section       = NullStr(row, "section"),
                    AcademicYear  = NullStr(row, "academic_year"),
                    GuardianName  = NullStr(row, "guardian_name"),
                    Mobile        = NullStr(row, "mobile"),
                    AdmissionDate = DbRead.NStr(row, "admission_date"),
                    DateOfLeaving = DbRead.NStr(row, "date_of_leaving"),
                    Status        = Str(row, "status"),
                    LeavingReason = NullStr(row, "leaving_reason"),
                    PublicId      = Has(row, "public_id") && row["public_id"] != DBNull.Value ? (Guid)row["public_id"] : Guid.Empty,
                    HasTc         = Has(row, "has_tc") && row["has_tc"] != DBNull.Value && Convert.ToBoolean(row["has_tc"]),
                    Outstanding   = DecVal(row, "outstanding")
                });
            }

            return query;
        }

        public async Task<string?> PeekNextAdmissionNoAsync(
            string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear))
                return null;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "next_adm_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_next_admission_no", parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var value = ds.Tables[0].Rows[0]["admission_no"];
            return value == DBNull.Value ? null : value.ToString();
        }

        public async Task<(bool Success, string Message, string? PhotoUrl)> SetStudentPhotoAsync(
            int studentId, string? photoUrl, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0)
                return (false, "Invalid student context.", null);

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_photo_url",      NpgsqlDbType.Varchar) { Value = (object?)photoUrl ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_photo_cursor" }
            };

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_student_set_photo", parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "Nothing was changed.", null);

                var row = ds.Tables[0].Rows[0];
                return (true, Str(row, "message"), NullStr(row, "photo_url"));
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Student photo update rejected for student {StudentId}. SqlState {SqlState}", studentId, ex.SqlState);
                return (false, ex.MessageText, null);
            }
        }

        public async Task<List<string>> GetClassSectionsAsync(string className, int tenantId, int schoolId, int actionUserId, string? academicYear = null)
        {
            var sections = new List<string>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return sections;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                new("p_class",     NpgsqlDbType.Varchar) { Value = className },
                new("p_academic_year", NpgsqlDbType.Varchar)
                    { Value = string.IsNullOrWhiteSpace(academicYear) ? DBNull.Value : academicYear.Trim() },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "class_setup_sections_cursor" }
            };

            // From the class setup, not from where students already sit: an empty
            // section (a new 5-C) has to be pickable on Edit Student and Promotion.
            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_class_setup_sections", parameters);
            if (ds.Tables.Count == 0) return sections;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var sec = NullStr(row, "section");
                if (!string.IsNullOrWhiteSpace(sec)) sections.Add(sec!);
            }
            return sections;
        }

        // ── Promotion ────────────────────────────────────────────
        // The student row is updated in place (there is no per-year enrolment
        // table), so the ledger and receipts keep pointing at the same
        // student_id. core.student_promotion_history holds the trail.
        public async Task<List<string>> GetClassLadderAsync(
            int tenantId, int schoolId, int actionUserId, string? academicYearName = null)
        {
            var classes = new List<string>();
            if (tenantId <= 1 || schoolId <= 0) return classes;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                // NULL = the current session. Classes are per-session rows, so the
                // ladder is meaningless without one.
                new("p_academic_year_name", NpgsqlDbType.Varchar)
                    { Value = string.IsNullOrWhiteSpace(academicYearName) ? DBNull.Value : academicYearName },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "class_ladder_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpClassLadder, parameters);
            if (ds.Tables.Count == 0) return classes;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var name = NullStr(row, "class_name");
                if (!string.IsNullOrWhiteSpace(name)) classes.Add(name!);
            }
            return classes;
        }

        public async Task<(bool Success, string Message)> UpdateStudentAsync(
            AdmissionModel model, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || model.StudentId <= 0)
                return (false, "Invalid school scope.");

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = model.StudentId },
                Txt("p_student_name",  model.StudentName),
                Txt("p_roll_no",       model.RollNo),
                Txt("p_gender",        model.Gender),
                new("p_dob", NpgsqlDbType.Unknown)
                    { Value = (object?)model.DateOfBirth ?? DBNull.Value },
                Txt("p_class_name",    model.ClassName),
                Txt("p_section",       model.Section),
                Txt("p_guardian_name", model.GuardianName),
                Txt("p_mother_name",   model.MotherName),
                Txt("p_mobile",        model.MobileNumber),
                Txt("p_alt_mobile",    model.AlternateMobile),
                Txt("p_address",       model.Address),
                Txt("p_blood_group",   model.BloodGroup),
                Txt("p_religion",      model.Religion),
                Txt("p_category",      model.Category),
                Txt("p_nationality",   model.Nationality),
                Txt("p_id_proof_no",   model.IdProofNo),
                Txt("p_prev_school",   model.PrevSchoolName),
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_update_cursor" },

                // The rest of the admission form. p_extended tells the proc these
                // are being sent; without it the stored values are kept.
                new("p_extended",      NpgsqlDbType.Boolean) { Value = true },
                Txt("p_mother_tongue",        model.MotherTongue),
                Txt("p_apaar_id",             model.ApaarId),
                Txt("p_udise_student_id",     model.UdiseStudentId),
                Txt("p_prev_board",           model.PrevBoard),
                Txt("p_prev_class",           model.PrevClass),
                Txt("p_prev_tc_no",           model.PrevTcNo),
                Txt("p_father_occupation",    model.FatherOccupation),
                Txt("p_father_qualification", model.FatherQualification),
                Txt("p_father_email",         model.FatherEmail),
                Txt("p_mother_occupation",    model.MotherOccupation),
                Txt("p_mother_qualification", model.MotherQualification),
                Txt("p_mother_email",         model.MotherEmail),
                new("p_annual_income", NpgsqlDbType.Numeric) { Value = (object?)model.AnnualIncome ?? DBNull.Value }
            };

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_student_update", p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "Nothing was updated.");

                var row = ds.Tables[0].Rows[0];
                return (true, Str(row, "message"));
            }
            catch (PostgresException ex)
            {
                // A proc RAISE is a business rule (unknown class, not this school's
                // student), so the office sees its wording.
                _logger.LogWarning(ex, "Student update rejected for student {StudentId}, school {SchoolId}. SqlState {SqlState}",
                    model.StudentId, schoolId, ex.SqlState);
                return (false, ex.MessageText);
            }
        }

        private static NpgsqlParameter Txt(string name, string? value) =>
            new(name, NpgsqlDbType.Text) { Value = (object?)value ?? DBNull.Value };
        public async Task<List<ClassLadderItem>> GetClassLadderDetailedAsync(
            int tenantId, int schoolId, int actionUserId, string? academicYearName = null)
        {
            var rungs = new List<ClassLadderItem>();
            if (tenantId <= 1 || schoolId <= 0) return rungs;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year_name", NpgsqlDbType.Varchar)
                    { Value = string.IsNullOrWhiteSpace(academicYearName) ? DBNull.Value : academicYearName },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "class_ladder_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpClassLadder, parameters);
            if (ds.Tables.Count == 0) return rungs;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var name = NullStr(row, "class_name");
                if (!string.IsNullOrWhiteSpace(name))
                    rungs.Add(new ClassLadderItem { Name = name!, Order = IntVal(row, "display_order") });
            }
            return rungs;
        }

        public async Task<List<PromotionHistoryRow>> GetPromotionHistoryAsync(
            string fromYear, bool onlyMyClass, int tenantId, int schoolId, int actionUserId)
        {
            var rows = new List<PromotionHistoryRow>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(fromYear)) return rows;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_from_year",      NpgsqlDbType.Varchar) { Value = fromYear.Trim() },
                new("p_only_my_class",  NpgsqlDbType.Boolean) { Value = onlyMyClass },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "promotion_history_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpPromotionHistory, parameters);
            if (ds.Tables.Count == 0) return rows;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                rows.Add(new PromotionHistoryRow
                {
                    PublicId      = Has(row, "public_id") && row["public_id"] != DBNull.Value ? (Guid)row["public_id"] : Guid.Empty,
                    StudentName   = Str(row, "student_name"),
                    AdmissionNo   = NullStr(row, "admission_no"),
                    FromClass     = Str(row, "from_class"),
                    FromSection   = NullStr(row, "from_section"),
                    ToYear        = NullStr(row, "to_year"),
                    ToClass       = NullStr(row, "to_class"),
                    ToSection     = NullStr(row, "to_section"),
                    Outcome       = Str(row, "outcome"),
                    DuesAtTheTime = DecVal(row, "dues_carried"),
                    PromotedBy    = NullStr(row, "promoted_by"),
                    PromotedAt    = Has(row, "promoted_at") && row["promoted_at"] != DBNull.Value ? Convert.ToDateTime(row["promoted_at"]) : null
                });
            }
            return rows;
        }

        public async Task<StudentPromotionResult> PromoteStudentsAsync(
            StudentPromotionRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new StudentPromotionResult { Message = "Invalid school scope." };

            if (request.Students == null || request.Students.Count == 0)
                return new StudentPromotionResult { Message = "No students were selected." };

            // camelCase keys — the proc reads them with quoted identifiers.
            // toClass rides inside the SAME jsonb payload rather than a new parameter, so
            // the proc signature is unchanged and an older deployed build keeps working.
            string studentsJson = JsonSerializer.Serialize(
                request.Students.Select(s => new
                {
                    studentId = s.StudentId,
                    outcome   = s.Outcome,
                    toClass   = string.IsNullOrWhiteSpace(s.ToClass) ? null : s.ToClass.Trim()
                }));

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_source_year",    NpgsqlDbType.Varchar) { Value = request.SourceYear ?? string.Empty },
                new("p_target_year",    NpgsqlDbType.Varchar) { Value = request.TargetYear ?? string.Empty },
                new("p_target_section", NpgsqlDbType.Varchar) { Value = (object?)request.TargetSection ?? DBNull.Value },
                new("p_carry_dues",     NpgsqlDbType.Boolean) { Value = request.CarryDues },
                new("p_students",       NpgsqlDbType.Jsonb)   { Value = studentsJson },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_promote_cursor" }
            };

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpStudentPromote, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new StudentPromotionResult { Message = "Nothing was changed." };

                var row = ds.Tables[0].Rows[0];
                return new StudentPromotionResult
                {
                    Success       = true,
                    Message       = Str(row, "message"),
                    Promoted      = IntVal(row, "promoted"),
                    Retained      = IntVal(row, "retained"),
                    PassedOut     = IntVal(row, "passed_out"),
                    Skipped       = IntVal(row, "skipped"),
                    SkippedDetail = NullStr(row, "skipped_detail")
                };
            }
            catch (PostgresException ex)
            {
                // The proc RAISEs the business rules ("final class", "session not
                // set up"), so the office sees that message rather than a stack.
                _logger.LogWarning(ex, "Promotion rejected for school {SchoolId}. SqlState {SqlState}", schoolId, ex.SqlState);
                return new StudentPromotionResult { Message = ex.MessageText };
            }
        }

        public async Task<List<StudentEnrolmentItem>> GetEnrolmentHistoryAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<StudentEnrolmentItem>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return items;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_enrolment_history_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpEnrolmentHistory, parameters);
            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                items.Add(new StudentEnrolmentItem
                {
                    AcademicYear = NullStr(row, "academic_year") ?? string.Empty,
                    ClassName    = NullStr(row, "class_name")    ?? string.Empty,
                    Section      = NullStr(row, "section"),
                    RollNo       = NullStr(row, "roll_no"),
                    Status       = NullStr(row, "status")        ?? string.Empty,
                    IsCurrent    = row.Table.Columns.Contains("is_current")
                                   && row["is_current"] != DBNull.Value
                                   && Convert.ToBoolean(row["is_current"])
                });
            }
            return items;
        }

        // ── Money across the lifecycle ───────────────────────────
        public async Task<Dictionary<string, int>> GetPlanInstalmentsAsync(
            string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear)) return map;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_from",           NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "plan_instalments_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_plan_instalments", parameters);
            if (ds.Tables.Count == 0) return map;
            foreach (DataRow row in ds.Tables[0].Rows)
            {
                map[Str(row, "frequency")] = IntVal(row, "instalments");
                // "due:Monthly" = instalments already due on the joining day (see sp_plan_instalments)
                map["due:" + Str(row, "frequency")] = IntVal(row, "due_now");
            }
            return map;
        }

        public async Task<StudentFeeTotals> GetStudentFeeTotalsAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var totals = new StudentFeeTotals();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return totals;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_fee_totals_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_student_fee_totals", parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return totals;

            var row = ds.Tables[0].Rows[0];
            totals.TotalDue        = DecVal(row, "total_due");
            totals.TotalPaid       = DecVal(row, "total_paid");
            totals.TotalConcession = DecVal(row, "total_concession");
            totals.TotalRefunded   = DecVal(row, "total_refunded");
            totals.TotalClosed     = DecVal(row, "total_closed");
            totals.Outstanding     = DecVal(row, "outstanding");
            totals.AdvanceBalance  = DecVal(row, "advance_balance");
            return totals;
        }

        public async Task<List<StudentHistoryItem>> GetStudentHistoryAsync(
            int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<StudentHistoryItem>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return items;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "student_history_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_student_history_get", parameters);
            if (ds.Tables.Count == 0) return items;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                items.Add(new StudentHistoryItem
                {
                    HappenedAt = Has(row, "happened_at") && row["happened_at"] != DBNull.Value
                                 ? Convert.ToDateTime(row["happened_at"]).ToString("dd MMM yyyy, HH:mm")
                                 : null,
                    Action     = Str(row, "action"),
                    Detail     = NullStr(row, "detail"),
                    Amount     = Has(row, "amount") && row["amount"] != DBNull.Value ? Convert.ToDecimal(row["amount"]) : null,
                    DoneBy     = NullStr(row, "done_by")
                });
            }
            return items;
        }

        // ── Mapper ───────────────────────────────────────────────
        private static StudentListModel MapListRow(DataRow row) => new()
        {
            StudentId      = IntVal(row, "student_id"),
            PublicId       = GuidVal(row, "public_id"),
            AdmissionNo    = Str(row, "admission_no"),
            RollNo         = NullStr(row, "roll_no"),
            StudentName    = Str(row, "student_name"),
            Gender         = NullStr(row, "gender"),
            ClassName      = Str(row, "class_name"),
            Section        = NullStr(row, "section"),
            AcademicYear   = Str(row, "academic_year"),
            AdmissionDate  = DbRead.NStr(row, "admission_date"),
            GuardianName   = NullStr(row, "guardian_name"),
            Mobile         = NullStr(row, "mobile"),
            AnnualTotal    = DecVal(row, "annual_total"),
            Status         = Has(row, "status") && row["status"] != DBNull.Value ? row["status"].ToString()! : "Active",
            ApprovalStatus = Has(row, "approval_status") && row["approval_status"] != DBNull.Value ? row["approval_status"].ToString()! : "Approved",
            FeeStatus      = Has(row, "fee_status") && row["fee_status"] != DBNull.Value ? row["fee_status"].ToString()! : "Pending",
            FeeDue         = DecVal(row, "fee_due"),
            FeeDueNow      = DecVal(row, "fee_due_now"),
            EnquiryId      = Has(row, "enquiry_id") && row["enquiry_id"] != DBNull.Value ? Convert.ToInt32(row["enquiry_id"]) : null,
            PhotoUrl       = NullStr(row, "photo_url")
        };

        // ── Tiny helpers (same style as EnquiryService) ──────────
        private static bool      Has(DataRow r, string col)     => r.Table.Columns.Contains(col);
        private static int       IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        // Guid.Empty when the column is absent — i.e. before public_id_students_staff.sql runs.
        private static Guid      GuidVal(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? (Guid)r[col] : Guid.Empty;
        private static decimal   DecVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : 0m;
        private static string    Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string?   NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
    }
}
