using System.Data;
using System.Text.Json;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class SubjectService : ISubjectService
    {
        private readonly PgExec _db;
        private const string Sp = "academic.sp_school_admin_subject_manage";

        public SubjectService(PgExec db)
        {
            _db = db;
        }

        public async Task<List<SubjectClassItem>> GetClassesAsync(
            int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            var list = new List<SubjectClassItem>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var p = Params("GetClasses", tenantId, schoolId, actionUserId);
            if (academicYearId > 0) p[4].Value = academicYearId;   // p_academic_year_id

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
            {
                list.Add(new SubjectClassItem
                {
                    AcademicClassId = IntVal(row, "academic_class_id"),
                    ClassName       = Str(row, "class_name"),
                    Stream          = NullStr(row, "stream"),
                    DisplayOrder    = IntVal(row, "display_order"),
                    SubjectCount    = IntVal(row, "subject_count")
                });
            }
            return list;
        }

        public async Task<List<SubjectItem>> GetClassSubjectsAsync(
            int academicClassId, int tenantId, int schoolId, int actionUserId, int academicYearId = 0)
        {
            if (academicClassId <= 0) return new List<SubjectItem>();

            var p = Params("GetClassSubjects", tenantId, schoolId, actionUserId);
            p[5].Value = academicClassId;      // p_academic_class_id
            if (academicYearId > 0) p[4].Value = academicYearId;   // p_academic_year_id

            return await ReadSubjectsAsync(p, tenantId, schoolId);
        }

        public async Task<List<SubjectItem>> GetSubjectMasterAsync(int tenantId, int schoolId, int actionUserId)
            => await ReadSubjectsAsync(Params("GetSubjectMaster", tenantId, schoolId, actionUserId), tenantId, schoolId);

        public async Task<SubjectSaveResult> SaveClassSubjectsAsync(
            int academicClassId, List<string> subjectNames, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0)
                return new SubjectSaveResult { Message = "Invalid school context." };
            if (academicClassId <= 0)
                return new SubjectSaveResult { Message = "Pick a class first." };

            // The proc works in names and creates any it hasn't seen before.
            var names = (subjectNames ?? new List<string>())
                .Select(n => (n ?? string.Empty).Trim())
                .Where(n => n.Length > 0)
                .ToList();

            var p = Params("SaveClassSubjects", tenantId, schoolId, actionUserId);
            p[5].Value = academicClassId;                    // p_academic_class_id
            p[6].Value = JsonSerializer.Serialize(names);    // p_items

            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
                if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0)
                    return new SubjectSaveResult { Message = "Nothing was saved." };

                var row = ds.Tables[0].Rows[0];
                return new SubjectSaveResult
                {
                    Success      = Has(row, "success") && row["success"] != DBNull.Value && Convert.ToBoolean(row["success"]),
                    SubjectCount = IntVal(row, "subject_count"),
                    Message      = string.IsNullOrEmpty(Str(row, "message")) ? "Subjects saved." : Str(row, "message")
                };
            }
            catch (PostgresException ex)
            {
                // Proc RAISE (e.g. a class from another school) — surface the friendly text.
                return new SubjectSaveResult { Message = ex.MessageText };
            }
        }

        private async Task<List<SubjectItem>> ReadSubjectsAsync(NpgsqlParameter[] p, int tenantId, int schoolId)
        {
            var list = new List<SubjectItem>();
            if (tenantId <= 1 || schoolId <= 0) return list;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(Sp, p);
            if (ds.Tables.Count == 0) return list;

            foreach (DataRow row in ds.Tables[0].Rows)
                list.Add(new SubjectItem { SubjectId = IntVal(row, "subject_id"), SubjectName = Str(row, "subject_name") });

            return list;
        }

        // Fixed positional layout matching sp_school_admin_subject_manage.
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
                new("p_items",             NpgsqlDbType.Text)    { Value = DBNull.Value },
                new("p_result",  NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "subject_cursor" },
                new("p_result2", NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "subject_cursor2" }
            };
        }

        private static bool Has(DataRow r, string col) => r.Table.Columns.Contains(col);
        private static int     IntVal(DataRow r, string col)  => Has(r, col) && r[col] != DBNull.Value ? Convert.ToInt32(r[col]) : 0;
        private static string  Str(DataRow r, string col)     => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string col) => Has(r, col) && r[col] != DBNull.Value ? r[col].ToString() : null;
    }
}
