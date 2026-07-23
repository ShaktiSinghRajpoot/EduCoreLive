using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class TransferCertificateService : ITransferCertificateService
    {
        private readonly PgExec _db;
        private const string Sp = "core.sp_tc_manage";

        public TransferCertificateService(PgExec db)
        {
            _db = db;
        }

        // The proc RAISEs its business rules ("clear the dues", "already issued"),
        // so the message the office sees comes straight from there.
        public async Task<TcIssueResult> IssueAsync(TcIssueRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || request.StudentId <= 0)
                return new TcIssueResult { Message = "Invalid student context." };

            var parameters = Params("Issue", tenantId, schoolId, actionUserId,
                studentId: request.StudentId,
                format:  request.Format,
                conduct: request.Conduct,
                result:  request.Result,
                reason:  request.Reason,
                remarks: request.Remarks,
                examResult:      request.ExamResult,
                failedStatus:    request.FailedStatus,
                subjects:        request.SubjectsStudied,
                feesPaidUpto:    request.FeesPaidUpto,
                workingDays:     request.WorkingDays,
                daysPresent:     request.DaysPresent,
                activities:      request.Activities,
                applicationDate: request.ApplicationDate);

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new TcIssueResult { Message = "Nothing was issued." };

                var row = ds.Tables[0].Rows[0];
                return new TcIssueResult
                {
                    Success = true,
                    Message = Str(row, "message"),
                    TcId    = IntVal(row, "tc_id"),
                    TcNo    = NullStr(row, "tc_no")
                };
            }
            catch (PostgresException ex)
            {
                return new TcIssueResult { Message = ex.MessageText };
            }
        }

        public async Task<TransferCertificate?> GetForPrintAsync(int tcId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || tcId <= 0) return null;

            var parameters = Params("Print", tenantId, schoolId, actionUserId, tcId: tcId);

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            return MapCertificate(ds.Tables[0].Rows[0]);
        }

        public async Task<TcListModel> GetListAsync(TcListModel query, int tenantId, int schoolId, int actionUserId)
        {
            query.Items = new List<TcListModel>();
            if (tenantId <= 1 || schoolId <= 0) { query.TotalCount = 0; return query; }

            var parameters = Params("List", tenantId, schoolId, actionUserId,
                search: query.Search, pageNo: query.Page, pageSize: query.PageSize);

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) { query.TotalCount = 0; return query; }

            query.TotalCount = IntVal(ds.Tables[0].Rows[0], "total_count");

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                query.Items.Add(new TcListModel
                {
                    TcId          = IntVal(row, "tc_id"),
                    TcNo          = Str(row, "tc_no"),
                    Format        = Str(row, "format"),
                    IssueDate     = DateVal(row, "issue_date"),
                    StudentId     = IntVal(row, "student_id"),
                    AdmissionNo   = NullStr(row, "admission_no"),
                    StudentName   = Str(row, "student_name"),
                    ClassName     = NullStr(row, "class_name"),
                    Section       = NullStr(row, "section"),
                    AcademicYear  = NullStr(row, "academic_year"),
                    DateOfLeaving = DateVal(row, "date_of_leaving"),
                    IsVoid        = BoolVal(row, "is_void"),
                    PrintCount    = IntVal(row, "print_count")
                });
            }

            return query;
        }

        public async Task<(bool Success, string Message)> VoidAsync(TcVoidRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || request.TcId <= 0)
                return (false, "Invalid certificate context.");

            var parameters = Params("Void", tenantId, schoolId, actionUserId,
                tcId: request.TcId, reason: request.Reason);

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "Nothing was changed.");

                return (true, Str(ds.Tables[0].Rows[0], "message"));
            }
            catch (PostgresException ex)
            {
                return (false, ex.MessageText);
            }
        }

        // ── one param builder for every operation (unused params stay NULL) ──
        // Order MUST match the sp_tc_manage signature — the call binds positionally.
        private static NpgsqlParameter[] Params(
            string operation, int tenantId, int schoolId, int actionUserId,
            int? tcId = null, int? studentId = null,
            string? format = null, string? conduct = null, string? result = null,
            string? reason = null, string? remarks = null,
            string? examResult = null, string? failedStatus = null, string? subjects = null,
            string? feesPaidUpto = null, int? workingDays = null, int? daysPresent = null,
            string? activities = null, DateOnly? applicationDate = null,
            string? search = null, int? pageNo = null, int? pageSize = null)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_tc_id",          NpgsqlDbType.Integer) { Value = (object?)tcId      ?? DBNull.Value },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = (object?)studentId ?? DBNull.Value },
                new("p_format",         NpgsqlDbType.Varchar) { Value = (object?)format    ?? DBNull.Value },
                new("p_conduct",        NpgsqlDbType.Varchar) { Value = (object?)conduct   ?? DBNull.Value },
                new("p_result",         NpgsqlDbType.Varchar) { Value = (object?)result    ?? DBNull.Value },
                new("p_reason",         NpgsqlDbType.Varchar) { Value = (object?)reason    ?? DBNull.Value },
                new("p_remarks",        NpgsqlDbType.Varchar) { Value = (object?)remarks   ?? DBNull.Value },
                new("p_exam_result",    NpgsqlDbType.Varchar) { Value = (object?)examResult   ?? DBNull.Value },
                new("p_failed_status",  NpgsqlDbType.Varchar) { Value = (object?)failedStatus ?? DBNull.Value },
                new("p_subjects",       NpgsqlDbType.Varchar) { Value = (object?)subjects     ?? DBNull.Value },
                new("p_fees_paid_upto", NpgsqlDbType.Varchar) { Value = (object?)feesPaidUpto ?? DBNull.Value },
                new("p_working_days",   NpgsqlDbType.Integer) { Value = (object?)workingDays  ?? DBNull.Value },
                new("p_days_present",   NpgsqlDbType.Integer) { Value = (object?)daysPresent  ?? DBNull.Value },
                new("p_activities",     NpgsqlDbType.Varchar) { Value = (object?)activities   ?? DBNull.Value },
                new("p_application_date", NpgsqlDbType.Date)  { Value = (object?)applicationDate ?? DBNull.Value },
                new("p_search",         NpgsqlDbType.Text)    { Value = (object?)search    ?? DBNull.Value },
                new("p_page_no",        NpgsqlDbType.Integer) { Value = (object?)pageNo    ?? DBNull.Value },
                new("p_page_size",      NpgsqlDbType.Integer) { Value = (object?)pageSize  ?? DBNull.Value },
                new("p_result_cur", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "tc_cursor" }
            };
        }

        private static TransferCertificate MapCertificate(DataRow row) => new()
        {
            TcId          = IntVal(row, "tc_id"),
            TcNo          = Str(row, "tc_no"),
            Format        = Str(row, "format"),
            IssueDate     = DateVal(row, "issue_date"),
            StudentId     = IntVal(row, "student_id"),
            AdmissionNo   = NullStr(row, "admission_no"),
            StudentName   = Str(row, "student_name"),
            Gender        = NullStr(row, "gender"),
            Dob           = DateVal(row, "dob"),
            FatherName    = NullStr(row, "father_name"),
            MotherName    = NullStr(row, "mother_name"),
            ClassName     = NullStr(row, "class_name"),
            Section       = NullStr(row, "section"),
            AcademicYear  = NullStr(row, "academic_year"),
            AdmissionDate = DateVal(row, "admission_date"),
            DateOfLeaving = DateVal(row, "date_of_leaving"),
            Religion      = NullStr(row, "religion"),
            Category      = NullStr(row, "category"),
            Nationality   = NullStr(row, "nationality"),
            Address       = NullStr(row, "address"),
            UdiseNo       = NullStr(row, "udise_no"),
            ReasonForLeaving = NullStr(row, "reason_for_leaving"),
            Conduct          = NullStr(row, "conduct"),
            Result           = NullStr(row, "result"),
            Remarks          = NullStr(row, "remarks"),
            OutstandingAtIssue = DecVal(row, "outstanding_at_issue"),
            ExamResult      = NullStr(row, "exam_result"),
            FailedStatus    = NullStr(row, "failed_status"),
            SubjectsStudied = NullStr(row, "subjects_studied"),
            FeesPaidUpto    = NullStr(row, "fees_paid_upto"),
            WorkingDays     = Has(row, "working_days") && row["working_days"] != DBNull.Value ? IntVal(row, "working_days") : null,
            DaysPresent     = Has(row, "days_present") && row["days_present"] != DBNull.Value ? IntVal(row, "days_present") : null,
            Activities      = NullStr(row, "activities"),
            ApplicationDate = DateVal(row, "application_date"),
            PrintCount    = IntVal(row, "print_count"),
            IsVoid        = BoolVal(row, "is_void"),
            WasDuplicate  = BoolVal(row, "was_duplicate")
        };

        // ── readers (same tolerant helpers as AdmissionService) ──
        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int      IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static decimal  DecVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : 0m;
        private static bool     BoolVal(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value && Convert.ToBoolean(r[col]);
        private static string   Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string?  NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
        private static DateOnly? DateVal(DataRow r, string col)
        {
            if (!Has(r, col) || r[col] == DBNull.Value) return null;
            var value = r[col];
            if (value is DateOnly d) return d;
            if (value is DateTime dt) return DateOnly.FromDateTime(dt);
            if (value is string s && DateTime.TryParse(s, out var parsed)) return DateOnly.FromDateTime(parsed);
            throw new InvalidCastException($"Unsupported date type: {value.GetType()}");
        }
    }
}
