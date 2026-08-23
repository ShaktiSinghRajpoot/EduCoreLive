using System.Data;
using System.Globalization;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class ExamService : IExamService
    {
        private readonly PgExec _db;
        private const string Sp      = "academic.sp_school_admin_exam_manage";
        private const string TimeFmt = "HH\\:mm";
        private const string SpMarks = "academic.sp_school_admin_exam_marks_manage";

        public ExamService(PgExec db)
        {
            _db = db;
        }

        public async Task<ExamListData> GetExamsAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var data = new ExamListData();
            if (tenantId <= 1 || schoolId <= 0) return data;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, WithYear(Params("GetExams", tenantId, schoolId, actionUserId), academicYearId));

            if (ds.Tables.Count > 0)
                foreach (DataRow row in ds.Tables[0].Rows)
                    data.Exams.Add(new ExamListItem
                    {
                        ExamId       = IntVal(row, "exam_id"),
                        ExamName     = Str(row, "exam_name"),
                        ExamType     = Str(row, "exam_type"),
                        TypeLabel    = Str(row, "type_label"),
                        StartDate    = DateStr(row, "start_date"),
                        EndDate      = DateStr(row, "end_date"),
                        ClassCount   = IntVal(row, "class_count"),
                        SubjectCount = IntVal(row, "subject_count"),
                        ClassNames   = Str(row, "class_names"),
                        Status       = Str(row, "status")
                    });

            // Second cursor carries the academic year, so the page needs no extra call.
            if (ds.Tables.Count > 1 && ds.Tables[1].Rows.Count > 0)
            {
                var meta = ds.Tables[1].Rows[0];
                data.AcademicYearId   = IntVal(meta, "academic_year_id");
                data.AcademicYearName = Str(meta, "academic_year_name");
            }

            return data;
        }

        public async Task<ExamDetail?> GetExamAsync(int examId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || examId <= 0) return null;

            var p = Params("GetExam", tenantId, schoolId, actionUserId);
            p[6].Value = examId;                       // p_exam_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;

            var head = ds.Tables[0].Rows[0];
            var exam = new ExamDetail
            {
                ExamId    = IntVal(head, "exam_id"),
                ExamName  = Str(head, "exam_name"),
                ExamType  = Str(head, "exam_type"),
                StartDate = DateStr(head, "start_date"),
                EndDate   = DateStr(head, "end_date")
            };

            // The datesheet arrives flat, ordered by class — group it back per class.
            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                {
                    var classId = IntVal(row, "academic_class_id");
                    var cls = exam.Classes.FirstOrDefault(c => c.AcademicClassId == classId);
                    if (cls == null)
                    {
                        cls = new ExamClassDatesheet
                        {
                            AcademicClassId = classId,
                            ClassName       = Str(row, "class_name"),
                            // Rides along on every row of the class; read it once.
                            Sections        = Str(row, "class_sections")
                                                .Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                                                .Select(x => x.Trim())
                                                .Where(x => x.Length > 0)
                                                .ToList()
                        };
                        exam.Classes.Add(cls);
                    }

                    cls.Subjects.Add(new ExamSubjectRow
                    {
                        SubjectId   = IntVal(row, "subject_id"),
                        SubjectName = Str(row, "subject_name"),
                        ExamDate    = NullDateStr(row, "exam_date"),
                        StartTime   = NullTimeStr(row, "start_time"),
                        EndTime     = NullTimeStr(row, "end_time"),
                        MaxMarks    = DecVal(row, "max_marks", 100),
                        PassMarks   = DecVal(row, "pass_marks", 35)
                    });
                }

            return exam;
        }

        public async Task<ExamSaveResult> SaveExamAsync(
            ExamSaveRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamSaveResult { Message = "Invalid school context." };
            if (request == null)
                return new ExamSaveResult { Message = "Nothing was posted." };
            if (string.IsNullOrWhiteSpace(request.ExamName))
                return new ExamSaveResult { Message = "Enter an exam name." };

            var start = ParseDate(request.StartDate);
            var end   = ParseDate(request.EndDate);
            if (start == null || end == null)
                return new ExamSaveResult { Message = "Enter the exam start and end dates." };
            if (end < start)
                return new ExamSaveResult { Message = "End date cannot be before the start date." };

            // Drop empty classes here so the proc's "class has no subjects" rule only
            // fires for a class the user really did leave blank.
            var classes = (request.Classes ?? new List<ExamClassInput>())
                .Where(c => c.ClassId > 0)
                .Select(c => new
                {
                    classId  = c.ClassId,
                    // Empty list = the whole class, which the proc stores as no rows.
                    sections = (c.Sections ?? new List<string>())
                        .Select(x => (x ?? string.Empty).Trim())
                        .Where(x => x.Length > 0)
                        .Distinct()
                        .ToList(),
                    subjects = (c.Subjects ?? new List<ExamSubjectInput>())
                        .Where(s => s.SubjectId > 0)
                        .Select(s => new
                        {
                            subjectId = s.SubjectId,
                            examDate  = ParseDate(s.ExamDate)?.ToString("yyyy-MM-dd") ?? string.Empty,
                            startTime = CleanTime(s.StartTime),
                            endTime   = CleanTime(s.EndTime),
                            maxMarks  = s.MaxMarks  ?? 100m,
                            passMarks = s.PassMarks ?? 35m
                        })
                        .ToList()
                })
                .Where(c => c.subjects.Count > 0)
                .ToList();

            if (classes.Count == 0)
                return new ExamSaveResult { Message = "Pick at least one class and give it some subjects." };

            var p = WithYear(Params("SaveExam", tenantId, schoolId, actionUserId), request.AcademicYearId);
            p[6].Value  = request.ExamId > 0 ? request.ExamId : (object)DBNull.Value;
            p[7].Value  = request.ExamName.Trim();                                // p_exam_name
            p[8].Value  = string.IsNullOrWhiteSpace(request.ExamType)             // p_exam_type
                            ? (object)DBNull.Value : request.ExamType.Trim();
            p[9].Value  = start.Value;                                            // p_start_date
            p[10].Value = end.Value;                                              // p_end_date
            p[12].Value = JsonSerializer.Serialize(classes);                      // p_items

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new ExamSaveResult { Message = "Nothing was saved." };

                var row = ds.Tables[0].Rows[0];
                return new ExamSaveResult
                {
                    Success      = BoolVal(row, "success"),
                    ExamId       = IntVal(row, "exam_id"),
                    ClassCount   = IntVal(row, "class_count"),
                    SubjectCount = IntVal(row, "subject_count"),
                    Message      = string.IsNullOrEmpty(Str(row, "message")) ? "Exam saved." : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // Proc RAISE (a business rule) — surface the friendly text.
                return new ExamSaveResult { Message = ex.MessageText };
            }
        }

        public async Task<ExamSaveResult> DeleteExamAsync(int examId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamSaveResult { Message = "Invalid school context." };
            if (examId <= 0)
                return new ExamSaveResult { Message = "Pick an exam to delete." };

            var p = Params("DeleteExam", tenantId, schoolId, actionUserId);
            p[6].Value = examId;                       // p_exam_id

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new ExamSaveResult { Message = "Nothing was deleted." };

                var row = ds.Tables[0].Rows[0];
                return new ExamSaveResult
                {
                    Success = BoolVal(row, "success"),
                    ExamId  = examId,
                    Message = string.IsNullOrEmpty(Str(row, "message")) ? "Exam deleted." : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                return new ExamSaveResult { Message = ex.MessageText };
            }
        }

        public async Task<ExamDatesheetData> GetDatesheetAsync(
            int academicClassId, int examId, int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var data = new ExamDatesheetData();
            if (tenantId <= 1 || schoolId <= 0) return data;

            var p = WithYear(Params("GetDatesheet", tenantId, schoolId, actionUserId), academicYearId);
            p[5].Value = academicClassId > 0 ? academicClassId : (object)DBNull.Value;
            p[6].Value = examId > 0 ? examId : (object)DBNull.Value;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);

            if (ds.Tables.Count > 0)
                foreach (DataRow row in ds.Tables[0].Rows)
                    data.Rows.Add(new ExamDatesheetRow
                    {
                        ExamDate        = NullDateStr(row, "exam_date"),
                        StartTime       = NullTimeStr(row, "start_time"),
                        EndTime         = NullTimeStr(row, "end_time"),
                        AcademicClassId = IntVal(row, "academic_class_id"),
                        ClassName       = Str(row, "class_name"),
                        SectionList     = Str(row, "section_list"),
                        SubjectName     = Str(row, "subject_name"),
                        MaxMarks        = DecVal(row, "max_marks", 100),
                        PassMarks       = DecVal(row, "pass_marks", 35),
                        ExamId          = IntVal(row, "exam_id"),
                        ExamName        = Str(row, "exam_name"),
                        TypeLabel       = Str(row, "type_label"),
                        HasClash        = BoolVal(row, "has_clash")
                    });

            if (ds.Tables.Count > 1 && ds.Tables[1].Rows.Count > 0)
                data.AcademicYearName = Str(ds.Tables[1].Rows[0], "academic_year_name");

            return data;
        }

        public async Task<List<ExamListRow>> GetExamListAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var list = new List<ExamListRow>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                Sp, WithYear(Params("GetExamList", tenantId, schoolId, actionUserId), academicYearId));
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
                list.Add(new ExamListRow
                {
                    ExamId           = IntVal(row, "exam_id"),
                    ExamName         = Str(row, "exam_name"),
                    TypeLabel        = Str(row, "type_label"),
                    AcademicYearName = Str(row, "academic_year_name"),
                    AcademicClassId  = IntVal(row, "academic_class_id"),
                    ClassName        = Str(row, "class_name"),
                    Section          = Str(row, "section"),
                    StartDate        = DateStr(row, "start_date"),
                    EndDate          = DateStr(row, "end_date"),
                    Status           = Str(row, "status"),
                    SubjectCount     = IntVal(row, "subject_count")
                });

            return list;
        }

        public async Task<List<ExamSheetSection>> GetClassSectionsAsync(
            int academicClassId, int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var list = new List<ExamSheetSection>();
            if (tenantId <= 1 || schoolId <= 0 || academicClassId <= 0) return list;

            var p = WithYear(Params("GetClassSections", tenantId, schoolId, actionUserId), academicYearId);
            p[5].Value = academicClassId;              // p_academic_class_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
                list.Add(new ExamSheetSection
                {
                    Section      = Str(row, "section"),
                    StudentCount = IntVal(row, "student_count")
                });

            return list;
        }

        public async Task<ExamSaveResult> SetExamStatusAsync(
            int examId, string status, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamSaveResult { Message = "Invalid school context." };
            if (examId <= 0)
                return new ExamSaveResult { Message = "Pick an exam first." };
            if (status != "Draft" && status != "Published")
                return new ExamSaveResult { Message = "Status must be Draft or Published." };

            var p = Params("SetStatus", tenantId, schoolId, actionUserId);
            p[6].Value  = examId;                      // p_exam_id
            p[11].Value = status;                      // p_status

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new ExamSaveResult { Message = "Nothing changed." };

                var row = ds.Tables[0].Rows[0];
                return new ExamSaveResult
                {
                    Success = BoolVal(row, "success"),
                    ExamId  = examId,
                    Message = string.IsNullOrEmpty(Str(row, "message")) ? "Status updated." : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                return new ExamSaveResult { Message = ex.MessageText };
            }
        }

        // -- Marks Entry --

        public async Task<List<ExamClassOption>> GetExamClassesAsync(
            int examId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<ExamClassOption>();
            if (tenantId <= 1 || schoolId <= 0 || examId <= 0) return list;

            var p = MarkParams("GetExamClasses", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                       // p_exam_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpMarks, p);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
                list.Add(new ExamClassOption
                {
                    AcademicClassId = IntVal(row, "academic_class_id"),
                    ClassName       = Str(row, "class_name"),
                    SubjectCount    = IntVal(row, "subject_count")
                });

            return list;
        }

        public async Task<ExamSheetSetup> GetClassSetupAsync(
            int examId, int academicClassId, int tenantId, int schoolId, int actionUserId)
        {
            var setup = new ExamSheetSetup();
            if (tenantId <= 1 || schoolId <= 0 || examId <= 0 || academicClassId <= 0) return setup;

            var p = MarkParams("GetClassSetup", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                       // p_exam_id
            p[5].Value = academicClassId;              // p_academic_class_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpMarks, p);

            if (ds.Tables.Count > 0)
                foreach (DataRow row in ds.Tables[0].Rows)
                    setup.Subjects.Add(new ExamSheetSubject
                    {
                        SubjectId   = IntVal(row, "subject_id"),
                        SubjectName = Str(row, "subject_name"),
                        ExamDate    = NullDateStr(row, "exam_date"),
                        StartTime   = NullTimeStr(row, "start_time"),
                        EndTime     = NullTimeStr(row, "end_time"),
                        MaxMarks    = DecVal(row, "max_marks", 100),
                        PassMarks   = DecVal(row, "pass_marks", 35)
                    });

            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                    setup.Sections.Add(new ExamSheetSection
                    {
                        Section      = Str(row, "section"),
                        StudentCount = IntVal(row, "student_count")
                    });

            return setup;
        }

        public async Task<ExamSheet?> GetSheetAsync(
            int examId, int academicClassId, int subjectId, string? section,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || examId <= 0 || academicClassId <= 0 || subjectId <= 0)
                return null;

            var p = MarkParams("GetSheet", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                                   // p_exam_id
            p[5].Value = academicClassId;                          // p_academic_class_id
            p[6].Value = subjectId;                                // p_subject_id
            p[7].Value = section ?? string.Empty;                  // p_section

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpMarks, p);
            var sheet = new ExamSheet();

            if (ds.Tables.Count > 0)
                foreach (DataRow row in ds.Tables[0].Rows)
                    sheet.Students.Add(new ExamMarkRow
                    {
                        StudentId   = IntVal(row, "student_id"),
                        RollNo      = Str(row, "roll_no"),
                        StudentName = Str(row, "student_name"),
                        Gender      = Str(row, "gender"),
                        Marks       = DecValN(row, "marks_obtained"),
                        IsAbsent    = BoolVal(row, "is_absent"),
                        HasMark     = BoolVal(row, "has_mark")
                    });

            if (ds.Tables.Count > 1 && ds.Tables[1].Rows.Count > 0)
            {
                var meta = ds.Tables[1].Rows[0];
                sheet.MaxMarks    = DecVal(meta, "max_marks", 100);
                sheet.PassMarks   = DecVal(meta, "pass_marks", 35);
                sheet.ExamDate    = NullDateStr(meta, "exam_date");
                sheet.StartTime   = NullTimeStr(meta, "start_time");
                sheet.EndTime     = NullTimeStr(meta, "end_time");
                sheet.SubjectName = Str(meta, "subject_name");
                sheet.IsFinalized = BoolVal(meta, "is_finalized");
                sheet.FinalizedAt = NullDateStr(meta, "finalized_at");
            }

            return sheet;
        }

        public async Task<ExamMarksSaveResult> SaveMarksAsync(
            ExamMarksSaveRequest request, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamMarksSaveResult { Message = "Invalid school context." };
            if (request == null || request.ExamId <= 0)
                return new ExamMarksSaveResult { Message = "Pick an exam first." };
            if (request.AcademicClassId <= 0)
                return new ExamMarksSaveResult { Message = "Pick a class first." };
            if (request.SubjectId <= 0)
                return new ExamMarksSaveResult { Message = "Pick a subject first." };

            // camelCase keys so they match the ->> lookups in the proc. Absent wins:
            // the proc drops the marks anyway, but sending them would be a lie.
            var itemsJson = JsonSerializer.Serialize(
                (request.Items ?? new List<ExamMarkInput>())
                .Where(i => i.StudentId > 0)
                .Select(i => new
                {
                    studentId = i.StudentId,
                    marks     = i.Absent ? null : i.Marks,
                    absent    = i.Absent
                }));

            var p = MarkParams("SaveMarks", tenantId, schoolId, actionUserId);
            p[4].Value = request.ExamId;                           // p_exam_id
            p[5].Value = request.AcademicClassId;                  // p_academic_class_id
            p[6].Value = request.SubjectId;                        // p_subject_id
            p[7].Value = request.Section ?? string.Empty;          // p_section
            p[8].Value = itemsJson;                                // p_items
            p[9].Value = request.Finalize;                         // p_finalize

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpMarks, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new ExamMarksSaveResult { Message = "Nothing was saved." };

                var row = ds.Tables[0].Rows[0];
                return new ExamMarksSaveResult
                {
                    Success      = BoolVal(row, "success"),
                    Saved        = IntVal(row, "saved"),
                    MarkedAbsent = IntVal(row, "marked_absent"),
                    IsFinalized  = BoolVal(row, "is_finalized"),
                    Message      = string.IsNullOrEmpty(Str(row, "message")) ? "Marks saved." : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                return new ExamMarksSaveResult { Message = ex.MessageText };
            }
        }

        public async Task<ExamMarksSaveResult> ReopenSheetAsync(
            int examId, int academicClassId, int subjectId, string? section,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new ExamMarksSaveResult { Message = "Invalid school context." };
            if (examId <= 0 || academicClassId <= 0 || subjectId <= 0)
                return new ExamMarksSaveResult { Message = "Pick an exam, class and subject first." };

            var p = MarkParams("ReopenSheet", tenantId, schoolId, actionUserId);
            p[4].Value = examId;                                   // p_exam_id
            p[5].Value = academicClassId;                          // p_academic_class_id
            p[6].Value = subjectId;                                // p_subject_id
            p[7].Value = section ?? string.Empty;                  // p_section

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpMarks, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new ExamMarksSaveResult { Message = "Nothing was reopened." };

                var row = ds.Tables[0].Rows[0];
                return new ExamMarksSaveResult
                {
                    Success = BoolVal(row, "success"),
                    Message = string.IsNullOrEmpty(Str(row, "message")) ? "Sheet reopened." : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                return new ExamMarksSaveResult { Message = ex.MessageText };
            }
        }

        // Fixed positional layout matching sp_school_admin_exam_manage.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",         NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",         NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",         NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",    NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year_id",  NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_academic_class_id", NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_exam_id",           NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_exam_name",         NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_exam_type",         NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_start_date",        NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_end_date",          NpgsqlDbType.Date)    { Value = DBNull.Value },
                new("p_status",            NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_items",             NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_result",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_cursor" },
                new("p_result2", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_cursor2" }
            };
        }

        // Fixed positional layout matching sp_school_admin_exam_marks_manage.
        private static NpgsqlParameter[] MarkParams(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",         NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",         NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",         NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id",    NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_exam_id",           NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_academic_class_id", NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_subject_id",        NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_section",           NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_items",             NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_finalize",          NpgsqlDbType.Boolean) { Value = false },
                new("p_result",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_marks_cursor" },
                new("p_result2", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "exam_marks_cursor2" }
            };
        }

        /// <summary>Point a param set at one session. 0 leaves it null = the current year.</summary>
        private static NpgsqlParameter[] WithYear(NpgsqlParameter[] p, int academicYearId)
        {
            if (academicYearId > 0) p[4].Value = academicYearId;   // p_academic_year_id
            return p;
        }

        private static DateOnly? ParseDate(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            return DateOnly.TryParse(value, CultureInfo.InvariantCulture, out var d) ? d : null;
        }

        // ── tolerant readers ──
        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static bool    BoolVal(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value && Convert.ToBoolean(r[col]);
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;

        private static decimal DecVal(DataRow r, string col, decimal fallback)
            => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : fallback;

        /// <summary>Nullable decimal — null means "no marks entered", not zero.</summary>
        private static decimal? DecValN(DataRow r, string col)
            => Has(r, col) && r[col] != DBNull.Value ? Convert.ToDecimal(r[col]) : null;

        /// <summary>Normalise an &lt;input type="time"&gt; value to HH:mm ("" when blank).</summary>
        private static string CleanTime(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return string.Empty;
            return TimeOnly.TryParse(value, CultureInfo.InvariantCulture, out var t)
                ? t.ToString(TimeFmt)
                : string.Empty;
        }

        /// <summary>
        /// A time column as HH:mm. Npgsql maps a Postgres `time` to TimeOnly, which
        /// is NOT IConvertible - the same trap as DateOnly, so cast, never Convert.
        /// </summary>
        private static string? NullTimeStr(DataRow r, string col)
        {
            if (!Has(r, col) || r[col] == DBNull.Value) return null;

            var v = r[col];
            if (v is TimeOnly t)  return t.ToString(TimeFmt);
            if (v is TimeSpan ts) return new TimeOnly(ts.Hours, ts.Minutes).ToString(TimeFmt);
            if (v is DateTime dt) return TimeOnly.FromDateTime(dt).ToString(TimeFmt);

            return TimeOnly.TryParse(v.ToString(), CultureInfo.InvariantCulture, out var p)
                ? p.ToString(TimeFmt)
                : null;
        }

        /// <summary>A date column as yyyy-MM-dd — what an &lt;input type="date"&gt; expects.</summary>
        private static string DateStr(DataRow r, string col) => NullDateStr(r, col) ?? string.Empty;

        /// <summary>
        /// Same DateOnly / DateTime / parse ladder as <see cref="EduCoreDataAccessLayer.Helpers.DbRead.Date"/>:
        /// Npgsql maps a Postgres `date` to DateOnly, which is NOT IConvertible, so
        /// Convert.ToDateTime on it throws "Unable to cast ... to type System.IConvertible".
        /// </summary>
        private static string? NullDateStr(DataRow r, string col)
        {
            if (!Has(r, col) || r[col] == DBNull.Value) return null;

            var v = r[col];
            if (v is DateOnly d)  return d.ToString("yyyy-MM-dd");
            if (v is DateTime dt) return dt.ToString("yyyy-MM-dd");

            return DateOnly.TryParse(v.ToString(), CultureInfo.InvariantCulture, out var p)
                ? p.ToString("yyyy-MM-dd")
                : null;
        }
    }
}
