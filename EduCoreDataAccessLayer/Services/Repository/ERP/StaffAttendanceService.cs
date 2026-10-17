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
    /// Staff attendance (core.sp_staff_attendance_manage) and substitute teachers
    /// (academic.sp_substitution_manage). Both procedures return two cursors.
    /// </summary>
    public class StaffAttendanceService : IStaffAttendanceService
    {
        private const string SpAttendance   = "core.sp_staff_attendance_manage";
        private const string SpSubstitution = "academic.sp_substitution_manage";
        private readonly PgExec _db;
        private readonly ILogger<StaffAttendanceService> _logger;

        public StaffAttendanceService(PgExec db, ILogger<StaffAttendanceService> logger)
        {
            _db = db;
            _logger = logger;
        }

        private static bool InScope(int tenantId, int schoolId) => tenantId > 1 && schoolId > 0;

        public async Task<StaffAttendanceHistory> GetHistoryAsync(int? staffId, string? from, string? to,
                                                                  int tenantId, int schoolId, int actionUserId)
        {
            var h = new StaffAttendanceHistory();
            if (!InScope(tenantId, schoolId)) return h;

            static object DateOrNull(string? d) =>
                DateTime.TryParseExact(d, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
                                       System.Globalization.DateTimeStyles.None, out var v) ? v : DBNull.Value;
            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_staff_id",       NpgsqlDbType.Integer) { Value = (object?)staffId ?? DBNull.Value },
                new("p_from",           NpgsqlDbType.Date)    { Value = DateOrNull(from) },
                new("p_to",             NpgsqlDbType.Date)    { Value = DateOrNull(to) },
                new("p_staff",   NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "sah_staff" },
                new("p_summary", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "sah_summary" },
                new("p_days",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "sah_days" }
            };

            await _db.ExecuteCursorsAsync("core.sp_staff_attendance_history", p,
                async reader =>
                {
                    var c = reader.Columns();
                    while (await reader.ReadAsync())
                        h.Staff.Add(new StaffPick
                        {
                            StaffId = DbRead.Int(reader, c, "staff_id"), FullName = DbRead.Str(reader, c, "full_name"),
                            EmployeeCode = DbRead.NStr(reader, c, "employee_code"), Designation = DbRead.NStr(reader, c, "designation"),
                            IsActive = DbRead.Bool(reader, c, "is_active")
                        });
                },
                async reader =>
                {
                    var c = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        h.WorkingDays = DbRead.Dec(reader, c, "working_days");
                        h.Present = DbRead.Int(reader, c, "present"); h.Late = DbRead.Int(reader, c, "late");
                        h.Absent = DbRead.Int(reader, c, "absent"); h.HalfDay = DbRead.Int(reader, c, "half_day");
                        h.OnLeave = DbRead.Int(reader, c, "on_leave"); h.NotMarked = DbRead.Int(reader, c, "not_marked");
                        h.Percent = DbRead.Dec(reader, c, "percent");
                        h.From = DbRead.NStr(reader, c, "from_date"); h.To = DbRead.NStr(reader, c, "to_date");
                    }
                },
                async reader =>
                {
                    var c = reader.Columns();
                    while (await reader.ReadAsync())
                        h.Days.Add(new StaffHistoryDay
                        {
                            Day = DbRead.Str(reader, c, "day"), Weekday = DbRead.Str(reader, c, "weekday"),
                            DayType = DbRead.Str(reader, c, "day_type"), Employed = DbRead.Bool(reader, c, "employed"),
                            Status = DbRead.NStr(reader, c, "status"), Remark = DbRead.NStr(reader, c, "remark"),
                            LeaveType = DbRead.NStr(reader, c, "leave_type")
                        });
                });
            return h;
        }

        // ── Attendance ───────────────────────────────────────────────────────
        public async Task<StaffDaySheet> GetDayAsync(string date, int tenantId, int schoolId, int actionUserId)
        {
            var sheet = new StaffDaySheet();
            var d = Dates.Parse(date);
            if (!InScope(tenantId, schoolId) || d == null) return sheet;

            await _db.ExecuteCursorsAsync(SpAttendance, AttParams("Day", tenantId, schoolId, actionUserId, date: d),
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        sheet.Staff.Add(new StaffDayRow
                        {
                            StaffId      = DbRead.Int(reader, cols, "staff_id"),
                            FullName     = DbRead.Str(reader, cols, "full_name"),
                            EmployeeCode = DbRead.NStr(reader, cols, "employee_code"),
                            Designation  = DbRead.NStr(reader, cols, "designation"),
                            StaffType    = DbRead.NStr(reader, cols, "staff_type"),
                            Status       = DbRead.NStr(reader, cols, "status"),
                            Remark       = DbRead.NStr(reader, cols, "remark"),
                            MarkedAt     = DbRead.DateTimeN(reader, cols, "marked_at"),
                            LeaveType    = DbRead.NStr(reader, cols, "leave_type")
                        });
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    if (await reader.ReadAsync())
                    {
                        sheet.CalendarNote = DbRead.NStr(reader, cols, "calendar_note");
                        sheet.DayOfWeek    = DbRead.Int(reader, cols, "dow");
                    }
                });
            return sheet;
        }

        public Task<(bool Success, string Message)> SaveDayAsync(string date, List<StaffDayRow> marks,
                                                                 int tenantId, int schoolId, int actionUserId)
        {
            var d = Dates.Parse(date);
            if (d == null) return Task.FromResult((false, "Choose a date."));

            var p = AttParams("Save", tenantId, schoolId, actionUserId, date: d);
            p[6].Value = marks.Select(m => m.StaffId).ToArray();
            p[7].Value = marks.Select(m => m.Status ?? "").ToArray();
            p[8].Value = marks.Select(m => m.Remark).ToArray();
            return WriteAsync(SpAttendance, p, "attendance save", tenantId, schoolId);
        }

        public async Task<StaffMonthRegister> GetMonthAsync(string month, int tenantId, int schoolId, int actionUserId)
        {
            var reg = new StaffMonthRegister();
            if (!InScope(tenantId, schoolId) || string.IsNullOrWhiteSpace(month)) return reg;

            await _db.ExecuteCursorsAsync(SpAttendance, AttParams("Month", tenantId, schoolId, actionUserId, month: month),
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        reg.Staff.Add(new StaffDayRow
                        {
                            StaffId     = DbRead.Int(reader, cols, "staff_id"),
                            FullName    = DbRead.Str(reader, cols, "full_name"),
                            Designation = DbRead.NStr(reader, cols, "designation"),
                            StaffType   = DbRead.NStr(reader, cols, "staff_type")
                        });
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        reg.Marks.Add(new StaffMonthMark
                        {
                            StaffId = DbRead.Int(reader, cols, "staff_id"),
                            Day     = DbRead.Int(reader, cols, "day"),
                            Status  = DbRead.Str(reader, cols, "status")
                        });
                });
            return reg;
        }

        // ── Substitutions ────────────────────────────────────────────────────
        public async Task<(List<SubstitutionNeed> Needs, List<TeacherLoad> Teachers)> GetSubstitutionDayAsync(
            string date, int tenantId, int schoolId, int actionUserId)
        {
            var needs = new List<SubstitutionNeed>();
            var teachers = new List<TeacherLoad>();
            var d = Dates.Parse(date);
            if (!InScope(tenantId, schoolId) || d == null) return (needs, teachers);

            await _db.ExecuteCursorsAsync(SpSubstitution, SubParams("Day", tenantId, schoolId, actionUserId, d),
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        needs.Add(new SubstitutionNeed
                        {
                            SectionId      = DbRead.Int(reader, cols, "section_id"),
                            PeriodSeq      = DbRead.Int(reader, cols, "period_seq"),
                            PeriodLabel    = DbRead.NStr(reader, cols, "period_label"),
                            SectionLabel   = DbRead.Str(reader, cols, "section_label"),
                            SubjectName    = DbRead.NStr(reader, cols, "subject_name"),
                            StaffId        = DbRead.Int(reader, cols, "staff_id"),
                            TeacherName    = DbRead.Str(reader, cols, "teacher_name"),
                            AwayReason     = DbRead.NStr(reader, cols, "away_reason"),
                            SubstituteId   = DbRead.IntN(reader, cols, "substitute_staff_id"),
                            SubstituteName = DbRead.NStr(reader, cols, "substitute_name")
                        });
                },
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        teachers.Add(new TeacherLoad
                        {
                            StaffId    = DbRead.Int(reader, cols, "staff_id"),
                            FullName   = DbRead.Str(reader, cols, "full_name"),
                            AwayReason = DbRead.NStr(reader, cols, "away_reason"),
                            Busy       = reader["busy"] is int[] busy ? busy.ToList() : new List<int>()
                        });
                });
            return (needs, teachers);
        }

        public Task<(bool Success, string Message)> AssignSubstituteAsync(string date, int sectionId, int periodSeq, int substituteId,
                                                                          int tenantId, int schoolId, int actionUserId)
        {
            var d = Dates.Parse(date);
            if (d == null) return Task.FromResult((false, "Choose a date."));
            return WriteAsync(SpSubstitution, SubParams("Assign", tenantId, schoolId, actionUserId, d, sectionId, periodSeq, substituteId),
                              "substitute assign", tenantId, schoolId);
        }

        public Task<(bool Success, string Message)> RemoveSubstituteAsync(string date, int sectionId, int periodSeq,
                                                                          int tenantId, int schoolId, int actionUserId)
        {
            var d = Dates.Parse(date);
            if (d == null) return Task.FromResult((false, "Choose a date."));
            return WriteAsync(SpSubstitution, SubParams("Remove", tenantId, schoolId, actionUserId, d, sectionId, periodSeq),
                              "substitute remove", tenantId, schoolId);
        }

        public async Task<List<MySubstitution>> GetMySubstitutionsAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<MySubstitution>();
            if (!InScope(tenantId, schoolId)) return list;

            await _db.ExecuteCursorsAsync(SpSubstitution, SubParams("Mine", tenantId, schoolId, actionUserId, null),
                async reader =>
                {
                    var cols = reader.Columns();
                    while (await reader.ReadAsync())
                        list.Add(new MySubstitution
                        {
                            Date         = DbRead.Str(reader, cols, "sub_date"),
                            DayLabel     = DbRead.Str(reader, cols, "day_label"),
                            PeriodSeq    = DbRead.Int(reader, cols, "period_seq"),
                            PeriodLabel  = DbRead.NStr(reader, cols, "period_label"),
                            SectionLabel = DbRead.Str(reader, cols, "section_label"),
                            SubjectName  = DbRead.NStr(reader, cols, "subject_name"),
                            OriginalName = DbRead.NStr(reader, cols, "original_name")
                        });
                },
                null);
            return list;
        }

        // ── Shared ───────────────────────────────────────────────────────────
        private async Task<(bool Success, string Message)> WriteAsync(string proc, NpgsqlParameter[] parameters, string what,
                                                                      int tenantId, int schoolId)
        {
            if (!InScope(tenantId, schoolId)) return (false, "Invalid request.");
            try
            {
                string msg = "Saved.";
                await _db.ExecuteCursorsAsync(proc, parameters,
                    async reader =>
                    {
                        var cols = reader.Columns();
                        if (await reader.ReadAsync())
                            msg = DbRead.NStr(reader, cols, "message") ?? msg;
                    },
                    null);
                return (true, msg);
            }
            catch (PostgresException pex)
            {
                _logger.LogWarning(pex, "Staff {What} rejected for school {SchoolId}. SqlState {SqlState}", what, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Unexpected error on staff {What} for school {SchoolId}.", what, schoolId);
                return (false, "Could not save. Please try again.");
            }
        }

        private static NpgsqlParameter[] AttParams(string operation, int tenantId, int schoolId, int actionUserId,
                                                   DateTime? date = null, string? month = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
            new("p_date",           NpgsqlDbType.Date)    { Value = (object?)date ?? DBNull.Value },
            new("p_month",          NpgsqlDbType.Text)    { Value = (object?)month ?? DBNull.Value },
            new("p_staff_ids", NpgsqlDbType.Array | NpgsqlDbType.Integer) { Value = DBNull.Value },
            new("p_statuses",  NpgsqlDbType.Array | NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_remarks",   NpgsqlDbType.Array | NpgsqlDbType.Varchar) { Value = DBNull.Value },
            new("p_result",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "staff_att_cursor" },
            new("p_result2", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "staff_att_cursor2" }
        };

        private static NpgsqlParameter[] SubParams(string operation, int tenantId, int schoolId, int actionUserId, DateTime? date,
                                                   int? sectionId = null, int? periodSeq = null, int? substituteId = null) => new NpgsqlParameter[]
        {
            new("p_operation",      NpgsqlDbType.Text)     { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer)  { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer)  { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer)  { Value = actionUserId },
            new("p_date",           NpgsqlDbType.Date)     { Value = (object?)date ?? DBNull.Value },
            new("p_section_id",     NpgsqlDbType.Integer)  { Value = (object?)sectionId ?? DBNull.Value },
            new("p_period_seq",     NpgsqlDbType.Smallint) { Value = periodSeq.HasValue ? (object)(short)periodSeq.Value : DBNull.Value },
            new("p_substitute_id",  NpgsqlDbType.Integer)  { Value = (object?)substituteId ?? DBNull.Value },
            new("p_result",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "subst_cursor" },
            new("p_result2", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "subst_cursor2" }
        };
    }
}
