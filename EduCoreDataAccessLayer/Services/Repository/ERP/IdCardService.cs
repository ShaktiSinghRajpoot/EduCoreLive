using System.Data;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class IdCardService : IIdCardService
    {
        private readonly PgExec _db;
        private const string Sp = "core.sp_id_card_students";
        private const string SpSections = "core.sp_id_card_sections";

        public IdCardService(PgExec db)
        {
            _db = db;
        }

        public async Task<List<IdCardStudent>> GetClassCardsAsync(
            string className, string? section, string? academicYear,
            int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className))
                return new List<IdCardStudent>();

            return await FetchAsync(tenantId, schoolId, actionUserId,
                className: className, section: section, academicYear: academicYear, studentId: null);
        }

        public async Task<IdCardStudent?> GetOneAsync(int studentId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || studentId <= 0) return null;

            var list = await FetchAsync(tenantId, schoolId, actionUserId,
                className: null, section: null, academicYear: null, studentId: studentId);
            return list.FirstOrDefault();
        }

        public async Task<List<string>> GetClassSectionsAsync(
            string className, string? academicYear, int tenantId, int schoolId, int actionUserId)
        {
            var sections = new List<string>();
            if (tenantId <= 1 || schoolId <= 0 || string.IsNullOrWhiteSpace(className)) return sections;

            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_class",          NpgsqlDbType.Varchar) { Value = className },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = (object?)academicYear ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "id_card_sections_cursor" }
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

        private async Task<List<IdCardStudent>> FetchAsync(
            int tenantId, int schoolId, int actionUserId,
            string? className, string? section, string? academicYear, int? studentId)
        {
            var parameters = new NpgsqlParameter[]
            {
                new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
                new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
                new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId },
                new("p_class",          NpgsqlDbType.Varchar) { Value = (object?)className    ?? DBNull.Value },
                new("p_section",        NpgsqlDbType.Varchar) { Value = (object?)section      ?? DBNull.Value },
                new("p_academic_year",  NpgsqlDbType.Varchar) { Value = (object?)academicYear ?? DBNull.Value },
                new("p_student_id",     NpgsqlDbType.Integer) { Value = (object?)studentId    ?? DBNull.Value },
                new("p_result", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "id_card_students_cursor" }
            };

            var list = new List<IdCardStudent>();
            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, parameters);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new IdCardStudent
                {
                    StudentId    = IntVal(row, "student_id"),
                    AdmissionNo  = NullStr(row, "admission_no"),
                    RollNo       = NullStr(row, "roll_no"),
                    StudentName  = Str(row, "student_name"),
                    ClassName    = NullStr(row, "class_name"),
                    Section      = NullStr(row, "section"),
                    AcademicYear = NullStr(row, "academic_year"),
                    Dob          = DateVal(row, "dob"),
                    BloodGroup   = NullStr(row, "blood_group"),
                    Gender       = NullStr(row, "gender"),
                    GuardianName = NullStr(row, "guardian_name"),
                    Mobile       = NullStr(row, "mobile"),
                    Address      = NullStr(row, "address"),
                    PhotoUrl     = NullStr(row, "photo_url")
                });
            }
            return list;
        }

        // ── tolerant readers (same helpers as the other services) ──
        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
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
