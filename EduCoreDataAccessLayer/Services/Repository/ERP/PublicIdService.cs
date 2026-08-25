using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    public class PublicIdService : IPublicIdService
    {
        private readonly PgExec _db;

        private const string SpResolve = "core.sp_resolve_public_id";

        public PublicIdService(PgExec db)
        {
            _db = db;
        }

        // The tenant/school check lives INSIDE core.fn_public_id_to_id, so another
        // school's uuid comes back NULL exactly like a uuid that does not exist.
        public async Task<int> ResolveAsync(string entity, Guid publicId, int tenantId, int schoolId)
        {
            if (tenantId <= 1 || schoolId <= 0 || publicId == Guid.Empty) return 0;

            var p = new[]
            {
                new NpgsqlParameter("p_entity",    NpgsqlDbType.Text)    { Value = entity },
                new NpgsqlParameter("p_public_id", NpgsqlDbType.Uuid)    { Value = publicId },
                new NpgsqlParameter("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                new NpgsqlParameter("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                new NpgsqlParameter("p_result",    NpgsqlDbType.Refcursor)
                    { Direction = ParameterDirection.InputOutput, Value = "resolve_public_id_cursor" }
            };

            var ds = await _db.ExecuteProcedureWithCursorsAsync(SpResolve, p);

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return 0;

            var row = ds.Tables[0].Rows[0];
            return row["id"] == DBNull.Value ? 0 : Convert.ToInt32(row["id"]);
        }
    }
}
