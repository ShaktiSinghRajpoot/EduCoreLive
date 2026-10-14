using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// Homework. One procedure, academic.sp_homework_manage, picked by p_operation
    /// (List | Save | Delete | Students | Check | Student). The procedure works out
    /// the caller's staff record and refuses changes to someone else's homework
    /// unless canManage.
    /// </summary>
    public class HomeworkService : IHomeworkService
    {
        private const string Sp = "academic.sp_homework_manage";
        private const string SpOverview = "academic.sp_homework_overview";
        private readonly PgExec _db;
        private readonly ILogger<HomeworkService> _logger;
        private readonly AppCache _cache;

        public HomeworkService(PgExec db, ILogger<HomeworkService> logger, AppCache cache)
        {
            _db = db;
            _logger = logger;
            _cache = cache;
        }

        private static bool InScope(int tenantId, int schoolId) => tenantId > 1 && schoolId > 0;

        public async Task<List<Homework>> GetListAsync(int? sectionId, string? from, string? to, bool mine, bool canManage,
                                                       int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<Homework>();
            if (!InScope(tenantId, schoolId)) return list;

            var p = Params("List", tenantId, schoolId, actionUserId, canManage);
            p[6].Value  = (object?)sectionId ?? DBNull.Value;
            p[10].Value = (object?)Dates.Parse(from) ?? DBNull.Value;
            p[11].Value = (object?)Dates.Parse(to) ?? DBNull.Value;
            p[12].Value = mine;
            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add(ReadHomework(reader, cols));
            });
            return list;
        }

        public async Task<HomeworkOverview> GetOverviewAsync(string from, string to, string? className,
                                                            int tenantId, int schoolId, int actionUserId)
        {
            var o = new HomeworkOverview();
            var f = Dates.Parse(from);
            var t = Dates.Parse(to);
            if (!InScope(tenantId, schoolId) || f == null || t == null) return o;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_from",           NpgsqlDbType.Date)    { Value = f.Value },
                new("p_to",             NpgsqlDbType.Date)    { Value = t.Value },
                new("p_class",          NpgsqlDbType.Text)    { Value = (object?)className ?? DBNull.Value },
                new("p_teachers", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "hw_teachers" },
                new("p_classes",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "hw_classes" },
                new("p_subjects", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "hw_subjects" }
            };

            await _db.ExecuteCursorsAsync(SpOverview, p,
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        var r = ReadOverviewRow(reader, cols, "full_name");
                        r.Id        = DbRead.Int(reader, cols, "staff_id");
                        r.Periods   = DbRead.Int(reader, cols, "periods");
                        r.Covered   = DbRead.Int(reader, cols, "covered");
                        r.LastGiven = DbRead.NStr(reader, cols, "last_given");
                        o.Teachers.Add(r);
                    }
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                    {
                        var r = ReadOverviewRow(reader, cols, "class_name");
                        r.Students = DbRead.Int(reader, cols, "students");
                        o.Classes.Add(r);
                    }
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        o.Subjects.Add(ReadOverviewRow(reader, cols, "subject_name"));
                });
            return o;
        }

        private static HomeworkOverviewRow ReadOverviewRow(NpgsqlDataReader reader, HashSet<string> cols, string nameColumn) => new HomeworkOverviewRow
        {
            Name        = DbRead.Str(reader, cols, nameColumn),
            Sections    = DbRead.Int(reader, cols, "sections"),
            Sets        = DbRead.Int(reader, cols, "sets"),
            CheckedSets = DbRead.Int(reader, cols, "checked_sets"),
            Expected    = DbRead.Int(reader, cols, "expected"),
            Recorded    = DbRead.Int(reader, cols, "recorded"),
            Done        = DbRead.Int(reader, cols, "done")
        };

        public Task<bool> TeachesAnyClassAsync(int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId)) return Task.FromResult(false);
            string key = AppCache.Key("teaches:u" + actionUserId, tenantId, schoolId);
            return _cache.GetOrCreateAsync(key, async () =>
                (await GetMyClassesAsync(tenantId, schoolId, actionUserId)).Count > 0, TimeSpan.FromMinutes(5));
        }

        public async Task<List<(int SectionId, int? SubjectId)>> GetMyClassesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<(int SectionId, int? SubjectId)>();
            if (!InScope(tenantId, schoolId)) return list;

            await _db.ExecuteCursorsAsync(Sp, Params("MyClasses", tenantId, schoolId, actionUserId, false), async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                    list.Add((DbRead.Int(reader, cols, "section_id"), DbRead.IntN(reader, cols, "subject_id")));
            });
            return list;
        }

        public async Task<List<Homework>> GetForStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<Homework>();
            if (!InScope(tenantId, schoolId) || studentId <= 0) return list;

            var p = Params("Student", tenantId, schoolId, actionUserId, true);
            p[15].Value = studentId;
            await _db.ExecuteCursorsAsync(Sp, p, async reader =>
            {
                var cols = reader.Columns();
                while (await reader.ReadAsync())
                {
                    var h = ReadHomework(reader, cols);
                    h.MyStatus = DbRead.NStr(reader, cols, "status");
                    list.Add(h);
                }
            });
            return list;
        }

        private static Homework ReadHomework(NpgsqlDataReader reader, HashSet<string> cols) => new Homework
        {
            Id           = DbRead.Int(reader, cols, "homework_id"),
            SectionId    = DbRead.Int(reader, cols, "section_id"),
            SectionLabel = DbRead.Str(reader, cols, "section_label"),
            SubjectId    = DbRead.Int(reader, cols, "subject_id"),
            SubjectName  = DbRead.Str(reader, cols, "subject_name"),
            TeacherName  = DbRead.NStr(reader, cols, "teacher_name"),
            Title        = DbRead.Str(reader, cols, "title"),
            Details      = DbRead.NStr(reader, cols, "details"),
            AssignedOn   = DbRead.Str(reader, cols, "assigned_on"),
            DueOn        = DbRead.Str(reader, cols, "due_on"),
            CanEdit      = DbRead.Bool(reader, cols, "can_edit"),
            DoneCount    = DbRead.Int(reader, cols, "done_count"),
            NotDoneCount = DbRead.Int(reader, cols, "not_done_count"),
            StudentCount = DbRead.Int(reader, cols, "student_count")
        };

        public async Task<List<HomeworkStudent>> GetStudentsAsync(int id, bool canManage, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<HomeworkStudent>();
            if (!InScope(tenantId, schoolId) || id <= 0) return list;

            var p = Params("Students", tenantId, schoolId, actionUserId, canManage);
            p[5].Value = id;
            try
            {
                await _db.ExecuteCursorsAsync(Sp, p, async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        list.Add(new HomeworkStudent
                        {
                            StudentId   = DbRead.Int(reader, cols, "student_id"),
                            StudentName = DbRead.Str(reader, cols, "student_name"),
                            RollNo      = DbRead.NStr(reader, cols, "roll_no"),
                            AdmissionNo = DbRead.NStr(reader, cols, "admission_no"),
                            Status      = DbRead.NStr(reader, cols, "status")
                        });
                });
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Homework {Id} students refused for school {SchoolId}. SqlState {SqlState}", id, schoolId, pex.SqlState);
            }
            return list;
        }

        public Task<(bool Success, string Message)> SaveAsync(Homework h, bool canManage, int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("Save", tenantId, schoolId, actionUserId, canManage);
            p[5].Value  = h.Id > 0 ? h.Id : DBNull.Value;
            p[6].Value  = h.SectionId;
            p[7].Value  = h.SubjectId;
            p[8].Value  = h.Title;
            p[9].Value  = (object?)h.Details ?? DBNull.Value;
            p[10].Value = (object?)Dates.Parse(h.AssignedOn) ?? DBNull.Value;
            p[11].Value = (object?)Dates.Parse(h.DueOn) ?? DBNull.Value;
            return WriteAsync(p, "save", tenantId, schoolId);
        }

        public Task<(bool Success, string Message)> DeleteAsync(int id, bool canManage, int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("Delete", tenantId, schoolId, actionUserId, canManage);
            p[5].Value = id;
            return WriteAsync(p, "delete", tenantId, schoolId);
        }

        public Task<(bool Success, string Message)> CheckAsync(int id, List<HomeworkStudent> marks, bool canManage,
                                                               int tenantId, int schoolId, int actionUserId)
        {
            var p = Params("Check", tenantId, schoolId, actionUserId, canManage);
            p[5].Value  = id;
            p[13].Value = marks.Select(m => m.StudentId).ToArray();
            p[14].Value = marks.Select(m => m.Status ?? "").ToArray();
            return WriteAsync(p, "check", tenantId, schoolId);
        }

        private async Task<(bool Success, string Message)> WriteAsync(NpgsqlParameter[] parameters, string what, int tenantId, int schoolId)
        {
            if (!InScope(tenantId, schoolId)) return (false, "Invalid request.");
            try
            {
                string msg = "Saved.";
                await _db.ExecuteCursorsAsync(Sp, parameters, async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                        msg = DbRead.NStr(reader, cols, "message") ?? msg;
                });
                return (true, msg);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Homework {What} rejected for school {SchoolId}. SqlState {SqlState}", what, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error on homework {What} for school {SchoolId}.", what, schoolId);
                return (false, "Could not save. Please try again.");
            }
        }

        // The callers fill the values they need by position; the order matches the procedure.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId, bool canManage) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },                      // 0
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },                       // 1
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },                       // 2
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },                   // 3
            new("p_can_manage",     NpgsqlDbType.Boolean) { Value = canManage },                      // 4
            new("p_id",             NpgsqlDbType.Integer) { Value = DBNull.Value },                   // 5
            new("p_section_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },                   // 6
            new("p_subject_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },                   // 7
            new("p_title",          NpgsqlDbType.Text)    { Value = DBNull.Value },                   // 8
            new("p_details",        NpgsqlDbType.Text)    { Value = DBNull.Value },                   // 9
            new("p_assigned_on",    NpgsqlDbType.Date)    { Value = DBNull.Value },                   // 10
            new("p_due_on",         NpgsqlDbType.Date)    { Value = DBNull.Value },                   // 11
            new("p_mine",           NpgsqlDbType.Boolean) { Value = false },                          // 12
            new("p_student_ids", NpgsqlDbType.Array | NpgsqlDbType.Integer) { Value = DBNull.Value }, // 13
            new("p_statuses",    NpgsqlDbType.Array | NpgsqlDbType.Varchar) { Value = DBNull.Value }, // 14
            new("p_student_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },                   // 15
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "homework_cursor" }
        };
    }
}
