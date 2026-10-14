using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class ClassTeacherService : IClassTeacherService
    {
        private readonly PgExec _db;
        private readonly ILogger<ClassTeacherService> _logger;
        private const string Sp = "core.sp_class_teacher_manage";

        public ClassTeacherService(PgExec db, ILogger<ClassTeacherService> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<List<ClassTeacherSection>> GetGridAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var list = new List<ClassTeacherSection>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = Params("Grid", tenantId, schoolId, actionUserId);
            if (academicYearId > 0) p[4].Value = academicYearId;   // p_academic_year_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new ClassTeacherSection
                {
                    SectionId   = IntVal(row, "section_id"),
                    ClassName   = Str(row, "class_name"),
                    ClassRank   = IntVal(row, "class_rank"),
                    SectionName = Str(row, "section_name"),
                    RoomNo      = NullStr(row, "room_no"),
                    TeacherId   = Has(row, "teacher_id") && row["teacher_id"] != DBNull.Value ? IntVal(row, "teacher_id") : null,
                    TeacherName = NullStr(row, "teacher_name"),
                    TeacherLoad = IntVal(row, "teacher_load")
                });
            }
            return list;
        }

        public async Task<List<ClassTeacherOption>> GetTeachersAsync(int tenantId, int schoolId, int actionUserId)
        {
            var list = new List<ClassTeacherOption>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, Params("Teachers", tenantId, schoolId, actionUserId));
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
                list.Add(new ClassTeacherOption { StaffId = IntVal(row, "staff_id"), FullName = Str(row, "full_name") });

            return list;
        }

        public async Task<(bool Success, string Message)> AssignAsync(
            int sectionId, int? staffId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || sectionId <= 0)
                return (false, "Invalid section.");

            var p = Params("Assign", tenantId, schoolId, actionUserId);
            p[5].Value = sectionId;               // p_section_id
            p[6].Value = (object?)staffId ?? DBNull.Value;   // p_staff_id

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return (false, "Nothing changed.");
                return (true, Str(ds.Tables[0].Rows[0], "message"));
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Class teacher assign refused (SqlState {SqlState}) for section {SectionId}",
                    ex.SqlState, sectionId);
                return (false, ex.MessageText);
            }
        }

        public async Task<bool> IsClassTeacherAsync(
            string className, string? section, int tenantId, int schoolId, int userId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return false;

            var p = Params("IsTeacher", tenantId, schoolId, userId);
            p[7].Value = className;                       // p_class
            p[8].Value = (object?)section ?? DBNull.Value; // p_section

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return false;

            var v = ds.Tables[0].Rows[0]["is_teacher"];
            return v != DBNull.Value && Convert.ToBoolean(v);
        }

        public async Task<(bool IsActing, string? ClassTeacher)> IsActingClassTeacherAsync(
            string className, string? section, string date, int tenantId, int schoolId, int userId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return (false, null);

            var p = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = userId },
                new("p_class",          NpgsqlDbType.Varchar) { Value = className },
                new("p_section",        NpgsqlDbType.Varchar) { Value = (object?)section ?? DBNull.Value },
                new("p_date",           NpgsqlDbType.Date)    { Value = DateTime.ParseExact(date, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture) },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "acting_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync("core.sp_class_teacher_acting", p);
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return (false, null);

            var row = ds.Tables[0].Rows[0];
            bool acting = row["is_acting"] != DBNull.Value && Convert.ToBoolean(row["is_acting"]);
            string? teacher = row["class_teacher"] == DBNull.Value ? null : row["class_teacher"].ToString();
            return (acting, teacher);
        }

        // Fixed positional layout matching sp_class_teacher_manage.
        private static NpgsqlParameter[] Params(string operation, int tenantId, int schoolId, int actionUserId)
        {
            return new NpgsqlParameter[]
            {
                new("p_operation",      NpgsqlDbType.Varchar) { Value = operation },
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_academic_year_id", NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_section_id",     NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_staff_id",       NpgsqlDbType.Integer) { Value = DBNull.Value },
                new("p_class",          NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_section",        NpgsqlDbType.Varchar) { Value = DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "class_teacher_cursor" }
            };
        }

        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
    }
}
