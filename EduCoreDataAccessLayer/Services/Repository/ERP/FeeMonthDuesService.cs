using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class FeeMonthDuesService : IFeeMonthDuesService
    {
        private readonly PgExec _db;

        public FeeMonthDuesService(PgExec db)
        {
            _db = db;
        }

        public async Task<FeeMonthDues> GetAsync(string academicYear, string? uptoMonth, string? className, string? section,
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
                new("p_upto_month",     NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(uptoMonth) ? DBNull.Value : uptoMonth.Trim() },
                new("p_class",          NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(className) ? DBNull.Value : className.Trim() },
                new("p_section",        NpgsqlDbType.Varchar) { Value = string.IsNullOrWhiteSpace(section) ? DBNull.Value : section.Trim() },
                new("p_months",   NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fmd_months" },
                new("p_classes",  NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fmd_classes" },
                new("p_students", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "fmd_students" }
            };

            await _db.ExecuteCursorsAsync("core.sp_fee_month_dues", p,
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
                            MayHaveLeft  = DbRead.Bool(r, cols, "may_have_left")
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
    }
}
