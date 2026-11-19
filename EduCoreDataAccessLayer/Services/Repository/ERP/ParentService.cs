using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// Parent module, Phase 1 (view only). See Database/parent_module.sql and
    /// educore/docs/PARENT-MODULE.md. Errors are not caught here: the parent
    /// controller turns a failure into a friendly page.
    /// </summary>
    public class ParentService : IParentService
    {
        private readonly PgExec _db;

        public ParentService(PgExec db)
        {
            _db = db;
        }

        private static NpgsqlParameter Cursor(string name, string value) =>
            new NpgsqlParameter(name, NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = value };

        private static bool InScope(int tenantId, int schoolId) => tenantId > 1 && schoolId > 0;

        public async Task<List<ParentChild>> GetChildrenAsync(string mobile)
        {
            var list = new List<ParentChild>();
            if (string.IsNullOrWhiteSpace(mobile)) return list;

            var p = new[]
            {
                new NpgsqlParameter("p_mobile", mobile),
                Cursor("p_result", "parent_children_cursor")
            };
            await _db.ExecuteCursorsAsync("core.sp_parent_children", p, async r =>
            {
                var c = r.Columns();
                while (await r.ReadAsync())
                {
                    list.Add(new ParentChild
                    {
                        StudentId    = DbRead.Int(r, c, "student_id"),
                        TenantId     = DbRead.Int(r, c, "tenant_id"),
                        SchoolId     = DbRead.Int(r, c, "school_id"),
                        SchoolName   = DbRead.Str(r, c, "school_name"),
                        StudentName  = DbRead.Str(r, c, "student_name"),
                        AdmissionNo  = DbRead.NStr(r, c, "admission_no"),
                        PhotoUrl     = DbRead.NStr(r, c, "photo_url"),
                        ClassName    = DbRead.NStr(r, c, "class_name"),
                        Section      = DbRead.NStr(r, c, "section"),
                        RollNo       = DbRead.NStr(r, c, "roll_no"),
                        ClassTeacher = DbRead.NStr(r, c, "class_teacher"),
                        AcademicYear = DbRead.NStr(r, c, "academic_year"),
                        SectionId    = DbRead.Int(r, c, "section_id"),
                        IsCurrent    = DbRead.Bool(r, c, "is_current"),
                        LeftOn       = DbRead.NStr(r, c, "left_on"),
                        ShowFees      = DbRead.Bool(r, c, "parent_show_fees"),
                        ShowReceipts  = DbRead.Bool(r, c, "parent_show_receipts"),
                        ShowResults   = DbRead.Bool(r, c, "parent_show_results"),
                        ShowHomework  = DbRead.Bool(r, c, "parent_show_homework"),
                        ShowTimetable = DbRead.Bool(r, c, "parent_show_timetable"),
                        ShowNotices   = DbRead.Bool(r, c, "parent_show_notices"),
                        FeesOn        = DbRead.Bool(r, c, "fees_on"),
                        AttendanceOn  = DbRead.Bool(r, c, "attendance_on"),
                        ExamsOn       = DbRead.Bool(r, c, "exams_on"),
                        AcademicsOn   = DbRead.Bool(r, c, "academics_on")
                    });
                }
            });
            return list;
        }

        public Task<ParentCodeResult> IssueCodeAsync(string mobile, string codeHash) => CodeAsync("Issue", mobile, codeHash);

        public Task<ParentCodeResult> VerifyCodeAsync(string mobile, string codeHash) => CodeAsync("Verify", mobile, codeHash);

        private async Task<ParentCodeResult> CodeAsync(string operation, string mobile, string codeHash)
        {
            var result = new ParentCodeResult();
            var p = new[]
            {
                new NpgsqlParameter("p_operation", operation),
                new NpgsqlParameter("p_mobile", mobile ?? string.Empty),
                new NpgsqlParameter("p_code_hash", codeHash ?? string.Empty),
                Cursor("p_result", "parent_code_cursor")
            };
            await _db.ExecuteCursorsAsync("core.sp_parent_login_code", p, async r =>
            {
                var c = r.Columns();
                if (await r.ReadAsync())
                {
                    result.Status      = DbRead.Str(r, c, "status");
                    result.WaitMinutes = DbRead.Int(r, c, "wait_minutes");
                    result.HasChildren = DbRead.Bool(r, c, "has_children");
                }
            });
            return result;
        }

        public async Task LogAsync(int tenantId, int schoolId, int studentId, string mobile, string action, string? detail)
        {
            if (!InScope(tenantId, schoolId) || studentId <= 0) return;
            var p = new[]
            {
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_student_id", studentId),
                new NpgsqlParameter("p_mobile", mobile ?? string.Empty),
                new NpgsqlParameter("p_action", action),
                new NpgsqlParameter("p_detail", (object?)detail ?? DBNull.Value) { NpgsqlDbType = NpgsqlDbType.Varchar }
            };
            await _db.ExecuteNonQueryProcedureAsync("core.sp_parent_access_log_add", p);
        }

        public async Task<List<ParentNotice>> GetNoticesAsync(int tenantId, int schoolId, string? className)
        {
            var list = new List<ParentNotice>();
            if (!InScope(tenantId, schoolId)) return list;
            var p = new[]
            {
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_class_name", (object?)className ?? DBNull.Value) { NpgsqlDbType = NpgsqlDbType.Varchar },
                Cursor("p_result", "parent_notices_cursor")
            };
            await _db.ExecuteCursorsAsync("core.sp_parent_notices", p, async r =>
            {
                var c = r.Columns();
                while (await r.ReadAsync())
                {
                    list.Add(new ParentNotice
                    {
                        Id       = DbRead.Int(r, c, "announcement_id"),
                        Title    = DbRead.Str(r, c, "title"),
                        Body     = DbRead.NStr(r, c, "body"),
                        Category = DbRead.NStr(r, c, "category"),
                        IsPinned = DbRead.Bool(r, c, "is_pinned"),
                        PostedOn = DbRead.NStr(r, c, "posted_on")
                    });
                }
            });
            return list;
        }

        public Task<List<ParentAccessMobile>> GetAccessAsync(int studentId, int tenantId, int schoolId, int actionUserId) =>
            AccessAsync("Get", studentId, null, tenantId, schoolId, actionUserId);

        public Task<List<ParentAccessMobile>> SetBlockedAsync(int studentId, string mobile, bool block, int tenantId, int schoolId, int actionUserId) =>
            AccessAsync(block ? "Block" : "Unblock", studentId, mobile, tenantId, schoolId, actionUserId);

        private async Task<List<ParentAccessMobile>> AccessAsync(string operation, int studentId, string? mobile,
                                                                 int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<ParentAccessMobile>();
            if (!InScope(tenantId, schoolId) || studentId <= 0) return list;
            var p = new[]
            {
                new NpgsqlParameter("p_operation", operation),
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_student_id", studentId),
                new NpgsqlParameter("p_mobile", (object?)mobile ?? DBNull.Value) { NpgsqlDbType = NpgsqlDbType.Varchar },
                Cursor("p_result", "parent_access_cursor")
            };
            await _db.ExecuteCursorsAsync("core.sp_parent_access_manage", p, async r =>
            {
                var c = r.Columns();
                while (await r.ReadAsync())
                {
                    list.Add(new ParentAccessMobile
                    {
                        Label       = DbRead.Str(r, c, "label"),
                        Mobile      = DbRead.Str(r, c, "mobile"),
                        IsBlocked   = DbRead.Bool(r, c, "is_blocked"),
                        LastLogin   = DbRead.NStr(r, c, "last_login"),
                        ParentAppOn = DbRead.Bool(r, c, "parent_app_on")
                    });
                }
            });
            return list;
        }

        public async Task<ParentLoginReport> GetLoginReportAsync(int tenantId, int schoolId, int actionUserId)
        {
            var report = new ParentLoginReport();
            if (!InScope(tenantId, schoolId)) return report;
            var p = new[]
            {
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                Cursor("p_classes", "parent_report_classes"),
                Cursor("p_log", "parent_report_log"),
                Cursor("p_never", "parent_report_never")
            };
            await _db.ExecuteCursorsAsync("core.sp_parent_login_report", p,
                async r =>
                {
                    var c = r.Columns();
                    while (await r.ReadAsync())
                        report.Classes.Add(new ParentLoginClassRow
                        {
                            ClassName = DbRead.Str(r, c, "class_name"),
                            Section   = DbRead.Str(r, c, "section"),
                            Students  = DbRead.Int(r, c, "students"),
                            LoggedIn  = DbRead.Int(r, c, "logged_in")
                        });
                },
                async r =>
                {
                    var c = r.Columns();
                    while (await r.ReadAsync())
                        report.Log.Add(new ParentLoginLogRow
                        {
                            AtTime      = DbRead.Str(r, c, "at_time"),
                            Mobile      = DbRead.Str(r, c, "mobile"),
                            Action      = DbRead.Str(r, c, "action"),
                            Detail      = DbRead.Str(r, c, "detail"),
                            StudentName = DbRead.Str(r, c, "student_name"),
                            ClassName   = DbRead.Str(r, c, "class_name"),
                            Section     = DbRead.Str(r, c, "section")
                        });
                },
                async r =>
                {
                    var c = r.Columns();
                    while (await r.ReadAsync())
                        report.Never.Add(new ParentLoginNeverRow
                        {
                            StudentName = DbRead.Str(r, c, "student_name"),
                            ClassName   = DbRead.Str(r, c, "class_name"),
                            Section     = DbRead.Str(r, c, "section"),
                            RollNo      = DbRead.Str(r, c, "roll_no")
                        });
                });
            return report;
        }

        public async Task SaveSchoolSettingsAsync(AdmissionWorkflowModel m, int tenantId, int schoolId, int actionUserId)
        {
            if (!InScope(tenantId, schoolId)) return;
            var p = new[]
            {
                new NpgsqlParameter("p_tenant_id", tenantId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_enable", m.EnableParentApp),
                new NpgsqlParameter("p_fees", m.ParentShowFees),
                new NpgsqlParameter("p_receipts", m.ParentShowReceipts),
                new NpgsqlParameter("p_results", m.ParentShowResults),
                new NpgsqlParameter("p_homework", m.ParentShowHomework),
                new NpgsqlParameter("p_timetable", m.ParentShowTimetable),
                new NpgsqlParameter("p_notices", m.ParentShowNotices),
                Cursor("p_result", "parent_settings_cursor")
            };
            await _db.ExecuteCursorsAsync("core.sp_parent_app_settings_save", p, (Func<NpgsqlDataReader, Task>?)null);
        }

        public async Task<(bool Allow, bool Enable)> GetPlatformAsync(int schoolId, int actionUserId) =>
            await PlatformAsync("Get", schoolId, null, actionUserId);

        public async Task SavePlatformAsync(int schoolId, bool allow, int actionUserId) =>
            await PlatformAsync("Save", schoolId, allow, actionUserId);

        private async Task<(bool Allow, bool Enable)> PlatformAsync(string operation, int schoolId, bool? allow, int actionUserId)
        {
            bool a = false, e = false;
            var p = new[]
            {
                new NpgsqlParameter("p_operation", operation),
                new NpgsqlParameter("p_action_user_id", actionUserId),
                new NpgsqlParameter("p_school_id", schoolId),
                new NpgsqlParameter("p_allow", (object?)allow ?? DBNull.Value) { NpgsqlDbType = NpgsqlDbType.Boolean },
                Cursor("p_result", "parent_app_cursor")
            };
            await _db.ExecuteCursorsAsync("core.sp_superadmin_parent_app", p, async r =>
            {
                var c = r.Columns();
                if (await r.ReadAsync())
                {
                    a = DbRead.Bool(r, c, "allow_parent_app");
                    e = DbRead.Bool(r, c, "enable_parent_app");
                }
            });
            return (a, e);
        }
    }
}
