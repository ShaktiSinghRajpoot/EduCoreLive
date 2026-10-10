using System.Data;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// Grade scale, result publishing and the class result sheet.
    /// Procs: exam_results_publish.sql.
    /// </summary>
    public class ExamResultService : IExamResultService
    {
        private readonly PgExec _db;
        private readonly AppCache _cache;
        private readonly ILogger<ExamResultService> _logger;
        private const string SpGrades  = "academic.sp_school_admin_grade_scale_manage";
        private const string SpResults = "academic.sp_school_admin_exam_results_manage";

        public ExamResultService(PgExec db, AppCache cache, ILogger<ExamResultService> logger)
        {
            _db = db;
            _cache = cache;
            _logger = logger;
        }

        // The grade scale is read-mostly reference data: cached per school, dropped on every write.
        private static string GradeScaleKey(int tenantId, int schoolId) => AppCache.Key("gradescale", tenantId, schoolId);

        // ── Grade scale ──

        public async Task<GradeScale> GetGradeScaleAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new GradeScale();

            return await _cache.GetOrCreateAsync(GradeScaleKey(tenantId, schoolId), async () =>
            {
                var scale = new GradeScale();
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    SpGrades, GradeParams("GetScale", tenantId, schoolId, actionUserId));
                if (ds.Tables.Count == 0) return scale;

                foreach (DataRow row in ds.Tables[0].Rows)
                {
                    scale.Bands.Add(new GradeBand
                    {
                        Label      = Str(row, "grade_label"),
                        MinPercent = DecVal(row, "min_percent", 0m),
                        MaxPercent = DecVal(row, "max_percent", 0m),
                        GradePoint = DecValN(row, "grade_point"),
                        Remark     = Has(row, "remark") && row["remark"] != DBNull.Value ? row["remark"].ToString() : null
                    });
                    scale.IsDefault = BoolVal(row, "is_default");
                }
                return scale;
            });
        }

        public async Task<ExamResultActionResult> SaveGradeScaleAsync(
            GradeScaleSaveRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamResultActionResult { Message = "Invalid school context." };
            if (request?.Bands == null || request.Bands.Count == 0)
                return new ExamResultActionResult { Message = "Add at least one grade band." };

            // camelCase keys so they match the ->> lookups in the proc. The proc does
            // every check (coverage, overlap, unique labels) so the rules live once.
            var itemsJson = JsonSerializer.Serialize(request.Bands.Select(b => new
            {
                label      = (b.Label ?? string.Empty).Trim(),
                minPercent = b.MinPercent,
                maxPercent = b.MaxPercent,
                gradePoint = b.GradePoint,
                remark     = (b.Remark ?? string.Empty).Trim()
            }));

            var p = GradeParams("SaveScale", tenantId, schoolId, actionUserId);
            p[4].Value = itemsJson;                    // p_items

            var result = await RunAsync(SpGrades, p, schoolId, "Grade scale saved.");
            _cache.Remove(GradeScaleKey(tenantId, schoolId));
            return result;
        }

        public async Task<ExamResultActionResult> ResetGradeScaleAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamResultActionResult { Message = "Invalid school context." };

            var result = await RunAsync(SpGrades, GradeParams("ResetDefault", tenantId, schoolId, actionUserId),
                                        schoolId, "Grade scale reset.");
            _cache.Remove(GradeScaleKey(tenantId, schoolId));
            return result;
        }

        // ── Result publishing ──

        public async Task<ExamResultStatus?> GetResultStatusAsync(int examId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || examId <= 0) return null;

            var p = ResultParams("GetStatus", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                       // p_exam_id

            DataSet ds;
            try
            {
                ds = await _db.ExecuteProcedureWithCursorsAsync(SpResults, p);
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Exam result status rejected for school {SchoolId}. SqlState {SqlState}", schoolId, ex.SqlState);
                return null;
            }
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var head = ds.Tables[0].Rows[0];
            var status = new ExamResultStatus
            {
                ExamId        = IntVal(head, "exam_id"),
                ExamName      = Str(head, "exam_name"),
                Status        = Str(head, "status"),
                ResultsStatus = Str(head, "results_status"),
                PublishedAt   = NullStr(head, "results_published_at"),
                PublishedBy   = NullStr(head, "results_published_by"),
                SheetCount    = IntVal(head, "sheet_count"),
                PendingCount  = IntVal(head, "pending_count")
            };

            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                    status.Pending.Add(new ExamPendingSheet
                    {
                        AcademicClassId = IntVal(row, "academic_class_id"),
                        ClassName       = Str(row, "class_name"),
                        Section         = Str(row, "section"),
                        SubjectName     = Str(row, "subject_name")
                    });

            if (ds.Tables.Count > 2)
                foreach (DataRow row in ds.Tables[2].Rows)
                    status.Log.Add(new ExamResultLogRow
                    {
                        Action = Str(row, "action"),
                        Reason = Str(row, "reason"),
                        DoneBy = Str(row, "done_by"),
                        DoneAt = Str(row, "done_at")
                    });

            return status;
        }

        public async Task<ExamResultActionResult> PublishResultsAsync(int examId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamResultActionResult { Message = "Invalid school context." };
            if (examId <= 0)
                return new ExamResultActionResult { Message = "Pick an exam first." };

            var p = ResultParams("PublishResults", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                       // p_exam_id
            return await RunAsync(SpResults, p, schoolId, "Results published.");
        }

        public async Task<ExamResultActionResult> UnpublishResultsAsync(
            int examId, string? reason, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamResultActionResult { Message = "Invalid school context." };
            if (examId <= 0)
                return new ExamResultActionResult { Message = "Pick an exam first." };
            if (string.IsNullOrWhiteSpace(reason))
                return new ExamResultActionResult { Message = "Give a reason for unpublishing the results." };

            var p = ResultParams("UnpublishResults", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                       // p_exam_id
            p[7].Value = reason.Trim();                // p_reason
            return await RunAsync(SpResults, p, schoolId, "Results unpublished.");
        }

        // ── Class result sheet ──

        public async Task<ClassResultSheet?> GetClassResultAsync(
            int examId, int academicClassId, string? section, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || examId <= 0 || academicClassId <= 0) return null;

            var p = ResultParams("GetClassResult", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                                   // p_exam_id
            p[5].Value = academicClassId;                          // p_academic_class_id
            p[6].Value = (section ?? string.Empty).Trim();         // p_section ('' = whole class)

            DataSet ds;
            try
            {
                ds = await _db.ExecuteProcedureWithCursorsAsync(SpResults, p);
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Class result rejected for school {SchoolId}. SqlState {SqlState}", schoolId, ex.SqlState);
                return null;
            }
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var head = ds.Tables[0].Rows[0];
            var sheet = new ClassResultSheet
            {
                ExamName         = Str(head, "exam_name"),
                ClassName        = Str(head, "class_name"),
                Section          = Str(head, "section"),
                Status           = Str(head, "status"),
                ResultsStatus    = Str(head, "results_status"),
                PublishedAt      = NullStr(head, "results_published_at"),
                AcademicYearName = Str(head, "academic_year_name"),
                PendingCount     = IntVal(head, "pending_count")
            };

            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                    sheet.Subjects.Add(new ClassResultSubject
                    {
                        SubjectId   = IntVal(row, "subject_id"),
                        SubjectName = Str(row, "subject_name"),
                        MaxMarks    = DecVal(row, "max_marks", 0m),
                        PassMarks   = DecVal(row, "pass_marks", 0m)
                    });

            // Students first, then their cells looked up by student id.
            var byId = new Dictionary<int, ClassResultStudent>();
            if (ds.Tables.Count > 2)
                foreach (DataRow row in ds.Tables[2].Rows)
                {
                    var s = new ClassResultStudent
                    {
                        StudentId   = IntVal(row, "student_id"),
                        RollNo      = Str(row, "roll_no"),
                        AdmissionNo = Str(row, "admission_no"),
                        StudentName = Str(row, "student_name"),
                        Section     = Str(row, "section"),
                        Obtained    = DecVal(row, "obtained", 0m),
                        Total       = DecVal(row, "total", 0m),
                        Percent     = DecValN(row, "percent"),
                        Grade       = NullStr(row, "grade"),
                        AbsentCount = IntVal(row, "absent_count"),
                        FailedCount = IntVal(row, "failed_count"),
                        ClassRank   = IntValN(row, "class_rank"),
                        SectionRank = IntValN(row, "section_rank"),
                        ClassSize   = IntVal(row, "class_size"),
                        SectionSize = IntVal(row, "section_size")
                    };
                    sheet.Students.Add(s);
                    byId[s.StudentId] = s;
                }

            if (ds.Tables.Count > 3)
                foreach (DataRow row in ds.Tables[3].Rows)
                {
                    if (!byId.TryGetValue(IntVal(row, "student_id"), out var s)) continue;
                    s.Cells.Add(new ClassResultCell
                    {
                        SubjectId = IntVal(row, "subject_id"),
                        Marks     = DecValN(row, "marks_obtained"),
                        IsAbsent  = BoolVal(row, "is_absent"),
                        Grade     = NullStr(row, "grade"),
                        Passed    = Has(row, "passed") && row["passed"] != DBNull.Value ? Convert.ToBoolean(row["passed"]) : null
                    });
                }

            return sheet;
        }

        // Run a write that answers with one (success, message) row.
        private async Task<ExamResultActionResult> RunAsync(string proc, NpgsqlParameter[] p, int schoolId, string fallback)
        {
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(proc, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new ExamResultActionResult { Message = "Nothing changed." };

                var row = ds.Tables[0].Rows[0];
                return new ExamResultActionResult
                {
                    Success = BoolVal(row, "success"),
                    Message = string.IsNullOrEmpty(Str(row, "message")) ? fallback : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // Proc RAISE (a business rule) — surface the friendly text.
                _logger.LogWarning(ex, "Exam result operation rejected for school {SchoolId}. SqlState {SqlState}", schoolId, ex.SqlState);
                return new ExamResultActionResult { Message = ex.MessageText };
            }
        }

        // Fixed positional layout matching sp_school_admin_grade_scale_manage.
        private static NpgsqlParameter[] GradeParams(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_items",          NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "grade_scale_cursor" }
            };
        }

        // Fixed positional layout matching sp_school_admin_exam_results_manage.
        private static NpgsqlParameter[] ResultParams(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",         NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",         NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",         NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",    NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_exam_id",           NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_academic_class_id", NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_section",           NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_reason",            NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_result",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_results_cursor" },
                new("p_result2", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_results_cursor2" },
                new("p_result3", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_results_cursor3" },
                new("p_result4", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_results_cursor4" }
            };
        }

        // ── tolerant readers ──
        private static bool    Has(DataRow r, string col)     => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static int?    IntValN(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : null;
        private static bool    BoolVal(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value && Convert.ToBoolean(r[col]);
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;

        private static decimal DecVal(DataRow r, string col, decimal fallback)
            => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : fallback;

        private static decimal? DecValN(DataRow r, string col)
            => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : null;
    }
}
