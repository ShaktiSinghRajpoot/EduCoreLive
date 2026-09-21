using System.Data;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class AttendanceService : IAttendanceService
    {
        private readonly PgExec _db;
        private const string SpSections = "core.sp_class_active_sections";
        private const string SpStudent  = "core.sp_attendance_student";
        private const string SpRoster   = "core.sp_attendance_roster";
        private const string SpSave     = "core.sp_attendance_save";
        private const string SpMonth    = "core.sp_attendance_month_register";

        public AttendanceService(PgExec db)
        {
            _db = db;
        }

        public async Task<List<string>> GetSectionsAsync(string className, int tenantId, int schoolId, int actionUserId)
        {
            var sections = new List<string>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return sections;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                new("p_class",     NpgsqlDbType.Varchar) { Value = className },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "class_sections_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpSections, parameters);
            if (ds.Tables.Count == 0) return sections;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                var sec = NullStr(row, "section");
                if (!string.IsNullOrWhiteSpace(sec)) sections.Add(sec);
            }
            return sections;
        }

        public async Task<StudentAttendanceSummary> GetStudentAttendanceAsync(
            int studentId, int tenantId, int schoolId, int actionUserId,
            string? academicYear = null, int? month = null, int? year = null)
        {
            var result = new StudentAttendanceSummary();
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return result;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = studentId },
                new("p_academic_year",  NpgsqlDbType.Varchar)
                    { Value = string.IsNullOrWhiteSpace(academicYear) ? DBNull.Value : academicYear },
                new("p_month", NpgsqlDbType.Integer) { Value = (object?)month ?? DBNull.Value },
                new("p_year",  NpgsqlDbType.Integer) { Value = (object?)year  ?? DBNull.Value },
                new("p_summary", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "as_summary" },
                new("p_months",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "as_months" },
                new("p_days",    NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "as_days" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpStudent, parameters);

            // Three cursors: summary, month list, day grid.
            if (ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0)
            {
                var row = ds.Tables[0].Rows[0];
                result.SchoolDays = IntVal(row, "school_days");
                result.Present    = IntVal(row, "present");
                result.Absent     = IntVal(row, "absent");
                result.LeaveDays  = IntVal(row, "leave_days");
                result.Percent    = Has(row, "percent") && row["percent"] != DBNull.Value
                                      ? Convert.ToDecimal(row["percent"]) : 0m;
            }

            if (ds.Tables.Count > 1)
            {
                foreach (DataRow row in ds.Tables[1].Rows)
                    result.Months.Add(new StudentAttendanceMonth
                    {
                        Month      = IntVal(row, "month"),
                        Year       = IntVal(row, "year"),
                        SchoolDays = IntVal(row, "school_days"),
                        Present    = IntVal(row, "present")
                    });
            }

            if (ds.Tables.Count > 2)
            {
                foreach (DataRow row in ds.Tables[2].Rows)
                    result.Days[IntVal(row, "day")] = Str(row, "mark");
            }

            return result;
        }

        public async Task<List<AttendanceStudent>> GetRosterAsync(
            string className, string? section, string date, int tenantId, int schoolId, int actionUserId)
        {
            var roster = new List<AttendanceStudent>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return roster;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_class",          NpgsqlDbType.Varchar) { Value = className },
                new("p_section",        NpgsqlDbType.Varchar) { Value = (object?)section ?? DBNull.Value },
                new("p_date",           NpgsqlDbType.Unknown)    { Value = date },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "attendance_roster_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpRoster, parameters);
            if (ds.Tables.Count == 0) return roster;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                roster.Add(new AttendanceStudent
                {
                    StudentId    = IntVal(row, "student_id"),
                    RollNo       = NullStr(row, "roll_no"),
                    AdmissionNo  = NullStr(row, "admission_no"),
                    StudentName  = Str(row, "student_name"),
                    GuardianName = NullStr(row, "guardian_name"),
                    Mobile       = NullStr(row, "mobile"),
                    Status      = NullStr(row, "status"),
                    Remarks     = NullStr(row, "remarks"),
                    IsMarked    = BoolVal(row, "is_marked")
                });
            }
            return roster;
        }

        public async Task<AttendanceSaveResult> SaveAsync(
            string date, List<AttendanceMark> marks, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new AttendanceSaveResult { Message = "Invalid school context." };
            if (marks == null || marks.Count == 0)
                return new AttendanceSaveResult { Message = "No students to save." };

            // camelCase keys so they match the quoted columns in sp_attendance_save.
            var itemsJson = JsonSerializer.Serialize(marks.Select(m => new
            {
                studentId = m.StudentId,
                status    = m.Status,
                remarks   = m.Remarks
            }));

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_date",           NpgsqlDbType.Unknown)    { Value = date },
                new("p_items",          NpgsqlDbType.Jsonb)   { Value = itemsJson },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "attendance_save_cursor" }
            };

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(SpSave, parameters);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new AttendanceSaveResult { Message = "Nothing was saved." };

                var row = ds.Tables[0].Rows[0];
                return new AttendanceSaveResult
                {
                    Success = true,
                    Message = Str(row, "message"),
                    Saved   = IntVal(row, "saved")
                };
            }
            catch (PostgresException ex)
            {
                return new AttendanceSaveResult { Message = ex.MessageText };
            }
        }

        public async Task<AttendanceMonthRegister> GetMonthRegisterAsync(
            string className, string? section, int month, int year, int tenantId, int schoolId, int actionUserId)
        {
            var result = new AttendanceMonthRegister();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return result;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_class",          NpgsqlDbType.Varchar) { Value = className },
                new("p_section",        NpgsqlDbType.Varchar) { Value = (object?)section ?? DBNull.Value },
                new("p_month",          NpgsqlDbType.Integer) { Value = month },
                new("p_year",           NpgsqlDbType.Integer) { Value = year },
                new("p_meta",     NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "ar_meta" },
                new("p_students", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "ar_students" },
                new("p_marks",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "ar_marks" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpMonth, parameters);

            if (ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0)
                result.SchoolDays = IntVal(ds.Tables[0].Rows[0], "school_days");

            if (ds.Tables.Count > 1)
                foreach (DataRow row in ds.Tables[1].Rows)
                    result.Students.Add(new AttendanceRosterEntry
                    {
                        Id   = IntVal(row, "student_id"),
                        Roll = NullStr(row, "roll_no"),
                        Name = Str(row, "student_name")
                    });

            if (ds.Tables.Count > 2)
                foreach (DataRow row in ds.Tables[2].Rows)
                    result.Marks.Add(new AttendanceDayMark
                    {
                        StudentId = IntVal(row, "student_id"),
                        Day       = IntVal(row, "day"),
                        Mark      = Str(row, "mark")
                    });

            return result;
        }

        // ── tolerant readers ──
        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static bool    BoolVal(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value && Convert.ToBoolean(r[col]);
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
    }
}
