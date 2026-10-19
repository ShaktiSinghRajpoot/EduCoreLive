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
    public class FeeMonthDuesService : IFeeMonthDuesService
    {
        private readonly PgExec _db;
        private readonly ILogger<FeeMonthDuesService> _logger;

        public FeeMonthDuesService(PgExec db, ILogger<FeeMonthDuesService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<FeeMonthDues> GetAsync(string academicYear, string? fromMonth, string? uptoMonth, string? className, string? section,
                                                 int tenantId, int schoolId, int actionUserId)
        {
            var res = new FeeMonthDues();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear)) return res;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_from_month",     NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(fromMonth) ? DBNull.Value : fromMonth.Trim() },
                new("p_upto_month",     NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(uptoMonth) ? DBNull.Value : uptoMonth.Trim() },
                new("p_class",          NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(className) ? DBNull.Value : className.Trim() },
                new("p_section",        NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(section) ? DBNull.Value : section.Trim() },
                new("p_months",   NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fmd_months" },
                new("p_classes",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fmd_classes" },
                new("p_students", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fmd_students" }
            };

            await _db.ExecuteCursorsAsync("core.sp_fee_month_dues", p,   // RAISE (from after to) reaches the controller
                async r =>
                {
                    var cols = r.Columns();
                    while (await r.ReadAsync())
                        res.Months.Add(new FeeDueMonth
                        {
                            Month     = DbRead.Str(r, cols, "month"),
                            Due       = DbRead.Dec(r, cols, "due"),
                            Collected = DbRead.Dec(r, cols, "collected"),
                            Pending   = DbRead.Dec(r, cols, "pending"),
                            Children  = DbRead.Int(r, cols, "children")
                        });
                },
                async r =>
                {
                    var cols = r.Columns();
                    while (await r.ReadAsync())
                        res.Classes.Add(new FeeDueClass
                        {
                            ClassName = DbRead.Str(r, cols, "class_name"),
                            Section   = DbRead.Str(r, cols, "section"),
                            Children  = DbRead.Int(r, cols, "children"),
                            WithDues  = DbRead.Int(r, cols, "with_dues"),
                            Pending   = DbRead.Dec(r, cols, "pending")
                        });
                },
                async r =>
                {
                    var cols = r.Columns();
                    while (await r.ReadAsync())
                        res.Students.Add(new FeeDueStudent
                        {
                            StudentId    = DbRead.Int(r, cols, "student_id"),
                            PublicId     = DbRead.Str(r, cols, "public_id"),
                            StudentName  = DbRead.Str(r, cols, "student_name"),
                            AdmissionNo  = DbRead.Str(r, cols, "admission_no"),
                            GuardianName = DbRead.Str(r, cols, "guardian_name"),
                            Mobile       = DbRead.Str(r, cols, "mobile"),
                            ClassName    = DbRead.Str(r, cols, "class_name"),
                            Section      = DbRead.Str(r, cols, "section"),
                            RollNo       = DbRead.Str(r, cols, "roll_no"),
                            Status       = DbRead.Str(r, cols, "kid_status"),
                            Pending      = DbRead.Dec(r, cols, "pending"),
                            MonthsCount  = DbRead.Int(r, cols, "months_count"),
                            Months       = DbRead.Str(r, cols, "months"),
                            OldestMonth  = DbRead.Str(r, cols, "oldest_month"),
                            LastPayment  = DbRead.Str(r, cols, "last_payment"),
                            LastPresent  = DbRead.Str(r, cols, "last_present"),
                            ClassDays    = DbRead.Int(r, cols, "class_days"),
                            PresentDays  = DbRead.Int(r, cols, "present_days"),
                            MayHaveLeft  = DbRead.Bool(r, cols, "may_have_left"),
                            LateFee      = DbRead.Dec(r, cols, "late_fee"),
                            LastReminded = DbRead.Str(r, cols, "last_reminded"),
                            FollowupNote = DbRead.Str(r, cols, "followup_note"),
                            PromiseDate  = DbRead.Str(r, cols, "promise_date"),
                            NoChase      = DbRead.Str(r, cols, "no_chase"),
                            OnHold       = DbRead.Bool(r, cols, "on_hold")
                        });
                });
            return res;
        }

        public async Task<AttendanceBrief?> GetAttendanceAsync(int studentId, string academicYear, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0 || string.IsNullOrWhiteSpace(academicYear)) return null;

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
                new("p_summary", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "sab_summary" },
                new("p_months",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "sab_months" }
            };

            AttendanceBrief? brief = null;
            var months = new List<AttendanceMonth>();
            await _db.ExecuteCursorsAsync("core.sp_student_attendance_brief", p,
                async r =>
                {
                    var cols = r.Columns();
                    if (await r.ReadAsync())
                        brief = new AttendanceBrief
                        {
                            StudentName  = DbRead.Str(r, cols, "student_name"),
                            LastPresent  = DbRead.Str(r, cols, "last_present"),
                            LastMarked   = DbRead.Str(r, cols, "last_marked"),
                            AbsentStreak = DbRead.Int(r, cols, "absent_streak"),
                            Marked       = DbRead.Int(r, cols, "marked"),
                            Present      = DbRead.Int(r, cols, "present")
                        };
                },
                async r =>
                {
                    var cols = r.Columns();
                    while (await r.ReadAsync())
                        months.Add(new AttendanceMonth
                        {
                            Month   = DbRead.Str(r, cols, "month"),
                            Present = DbRead.Int(r, cols, "present"),
                            Absent  = DbRead.Int(r, cols, "absent"),
                            OnLeave = DbRead.Int(r, cols, "on_leave")
                        });
                });
            if (brief != null) brief.Months = months;
            return brief;
        }

        // ── chasing (fee_dues_followup.sql) ─────────────────────────────────

        public async Task<List<FeeFollowup>> GetFollowupsAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<FeeFollowup>();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return list;
            var p = FollowupParams("List", tenantId, schoolId, actionUserId);
            p[4].Value = studentId;
            await _db.ExecuteCursorsAsync("core.sp_fee_followup", p, async rd =>
            {
                var cols = rd.Columns();
                while (await rd.ReadAsync())
                    list.Add(new FeeFollowup
                    {
                        FollowupId  = DbRead.Int(rd, cols, "followup_id"),
                        Note        = DbRead.Str(rd, cols, "note"),
                        PromiseDate = DbRead.Str(rd, cols, "promise_date"),
                        IsDone      = DbRead.Bool(rd, cols, "is_done"),
                        CreatedOn   = DbRead.Str(rd, cols, "created_on"),
                        CreatedBy   = DbRead.Str(rd, cols, "created_by_name")
                    });
            });
            return list;
        }

        public Task<FeeDuesResult> AddFollowupAsync(int studentId, string note, string? promiseDate, int tenantId, int schoolId, int actionUserId)
        {
            var p = FollowupParams("Add", tenantId, schoolId, actionUserId);
            p[4].Value = studentId;
            p[5].Value = note ?? string.Empty;
            p[6].Value = string.IsNullOrWhiteSpace(promiseDate) ? DBNull.Value : promiseDate.Trim();
            return RunAsync("core.sp_fee_followup", p, tenantId, schoolId);
        }

        public Task<FeeDuesResult> FollowupDoneAsync(int followupId, int tenantId, int schoolId, int actionUserId)
        {
            var p = FollowupParams("Done", tenantId, schoolId, actionUserId);
            p[7].Value = followupId;
            return RunAsync("core.sp_fee_followup", p, tenantId, schoolId);
        }

        public Task<FeeDuesResult> SetNoChaseAsync(int studentId, string? reason, string? until, bool on, int tenantId, int schoolId, int actionUserId)
        {
            var p = new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = on ? "Set" : "Clear" },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_reason",         NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(reason) ? DBNull.Value : reason.Trim() },
                new("p_until",          NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(until) ? DBNull.Value : until.Trim() },
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_no_chase_cursor" }
            };
            return RunAsync("core.sp_fee_no_chase", p, tenantId, schoolId);
        }

        public async Task<FeeDuesSettings> GetSettingsAsync(int tenantId, int schoolId, int actionUserId)
        {
            var res = new FeeDuesSettings();
            if (tenantId <= 1 || schoolId <= 0) return res;
            await _db.ExecuteCursorsAsync("core.sp_fee_dues_settings", SettingsParams("Get", null, tenantId, schoolId, actionUserId), async rd =>
            {
                var cols = rd.Columns();
                if (await rd.ReadAsync())
                {
                    res.LateFeeAmount = DbRead.Dec(rd, cols, "late_fee_amount");
                    res.GraceDays     = DbRead.Int(rd, cols, "grace_days");
                    res.HoldMonths    = DbRead.Int(rd, cols, "hold_months");
                }
            });
            return res;
        }

        public async Task<FeeDuesResult> SaveSettingsAsync(FeeDuesSettings s, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new FeeDuesResult { Message = "Invalid school." };
            try
            {
                await _db.ExecuteCursorsAsync("core.sp_fee_dues_settings", SettingsParams("Save", s, tenantId, schoolId, actionUserId),
                    async rd => { await rd.ReadAsync(); });
                return new FeeDuesResult { Success = true, Message = "Settings saved." };
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Fee dues settings rejected. SqlState {SqlState}", ex.SqlState);
                return new FeeDuesResult { Message = ex.MessageText };
            }
        }

        public async Task<List<LateFeeLine>> PreviewLateFeesAsync(string academicYear, List<int>? studentIds, int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<LateFeeLine>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(academicYear)) return list;
            await _db.ExecuteCursorsAsync("core.sp_fee_late_fee", LateFeeParams("Preview", academicYear, studentIds, tenantId, schoolId, actionUserId), async rd =>
            {
                var cols = rd.Columns();
                while (await rd.ReadAsync())
                    list.Add(new LateFeeLine
                    {
                        StudentId   = DbRead.Int(rd, cols, "student_id"),
                        StudentName = DbRead.Str(rd, cols, "student_name"),
                        ClassName   = DbRead.Str(rd, cols, "class_name"),
                        Section     = DbRead.Str(rd, cols, "section"),
                        Month       = DbRead.Str(rd, cols, "month"),
                        Amount      = DbRead.Dec(rd, cols, "amount")
                    });
            });
            return list;
        }

        public Task<FeeDuesResult> ApplyLateFeesAsync(string academicYear, List<int>? studentIds, int tenantId, int schoolId, int actionUserId)
            => RunAsync("core.sp_fee_late_fee", LateFeeParams("Apply", academicYear, studentIds, tenantId, schoolId, actionUserId), tenantId, schoolId);

        // Runs a proc whose cursor answers success / message (/ added); a RAISE becomes the message.
        private async Task<FeeDuesResult> RunAsync(string proc, NpgsqlParameter[] p, int tenantId, int schoolId)
        {
            if (tenantId <= 1 || schoolId <= 0) return new FeeDuesResult { Message = "Invalid school." };
            try
            {
                var res = new FeeDuesResult { Message = "Nothing was changed." };
                await _db.ExecuteCursorsAsync(proc, p, async rd =>
                {
                    var cols = rd.Columns();
                    if (await rd.ReadAsync())
                    {
                        res.Success = DbRead.Bool(rd, cols, "success");
                        res.Message = DbRead.Str(rd, cols, "message");
                        res.Count   = DbRead.Int(rd, cols, "added");
                    }
                });
                return res;
            }
            catch (PostgresException ex)
            {
                // a proc RAISE: empty note, no late fee set, not found ...
                _logger.LogWarning(ex, "{Proc} rejected. SqlState {SqlState}", proc, ex.SqlState);
                return new FeeDuesResult { Message = ex.MessageText };
            }
        }

        private static NpgsqlParameter[] FollowupParams(string op, int tenantId, int schoolId, int actionUserId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Varchar) { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_student_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_note",           NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_promise_date",   NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_followup_id",    NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_followup_cursor" }
        };

        private static NpgsqlParameter[] SettingsParams(string op, FeeDuesSettings? s, int tenantId, int schoolId, int actionUserId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Varchar) { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_late_fee",       NpgsqlDbType.Numeric) { Value = s == null ? DBNull.Value : s.LateFeeAmount },
            new("p_grace_days",     NpgsqlDbType.Integer) { Value = s == null ? DBNull.Value : s.GraceDays },
            new("p_hold_months",    NpgsqlDbType.Integer) { Value = s == null ? DBNull.Value : s.HoldMonths },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_dues_settings_cursor" }
        };

        private static NpgsqlParameter[] LateFeeParams(string op, string academicYear, List<int>? ids, int tenantId, int schoolId, int actionUserId) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Varchar) { Value = op },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_academic_year",  NpgsqlDbType.Varchar) { Value = academicYear.Trim() },
            new("p_student_ids",    NpgsqlDbType.Jsonb)   { Value = ids == null || ids.Count == 0 ? DBNull.Value : System.Text.Json.JsonSerializer.Serialize(ids) },
            new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fee_late_fee_cursor" }
        };
    }
}
