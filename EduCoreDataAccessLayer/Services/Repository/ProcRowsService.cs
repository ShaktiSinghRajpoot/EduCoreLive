using System.Data;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace EduCoreDataAccessLayer.Services.Repository
{
    /// <summary>
    /// Base for the small modules built on one "manage" procedure with operations
    /// (Rooms, Front Office, Accounts, Library, Hostel). Lists come back as plain rows
    /// (column -> value) because the page only draws them; writes return the
    /// procedure's message, and a RAISE in the procedure becomes the message shown.
    /// Every call still passes tenant / school / user, and a call outside a school
    /// scope never reaches the database.
    /// </summary>
    public abstract class ProcRowsService
    {
        protected readonly PgExec Db;
        protected readonly ILogger Logger;

        protected ProcRowsService(PgExec db, ILogger logger)
        {
            Db = db;
            Logger = logger;
        }

        protected static bool InScope(int tenantId, int schoolId) => tenantId > 1 && schoolId > 0;

        /// <summary>The parameters every manage procedure starts with.</summary>
        protected static List<NpgsqlParameter> Head(string operation, int tenantId, int schoolId, int actionUserId) => new()
        {
            new("p_operation",      NpgsqlDbType.Text)    { Value = operation },
            new("p_tenant_id",      NpgsqlDbType.Integer) { Value = tenantId },
            new("p_school_id",      NpgsqlDbType.Integer) { Value = schoolId },
            new("p_action_user_id", NpgsqlDbType.Integer) { Value = actionUserId }
        };

        protected static NpgsqlParameter Text(string name, string? value)
            => new(name, NpgsqlDbType.Text) { Value = string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim() };
        protected static NpgsqlParameter Int(string name, int? value)
            => new(name, NpgsqlDbType.Integer) { Value = (object?)value ?? DBNull.Value };
        protected static NpgsqlParameter Num(string name, decimal? value)
            => new(name, NpgsqlDbType.Numeric) { Value = (object?)value ?? DBNull.Value };
        protected static NpgsqlParameter Date(string name, string? isoDate)
            => new(name, NpgsqlDbType.Date) { Value = (object?)Dates.Parse(isoDate) ?? DBNull.Value };
        protected static NpgsqlParameter Bool(string name, bool? value)
            => new(name, NpgsqlDbType.Boolean) { Value = (object?)value ?? DBNull.Value };
        protected static NpgsqlParameter Cursor(string name = "p_result")
            => new(name, NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = name.Replace("p_", "") + "_cursor" };

        /// <summary>Rows of the procedure's (single) cursor.</summary>
        protected async Task<List<Dictionary<string, object?>>> RowsAsync(string proc, List<NpgsqlParameter> p, int tenantId, int schoolId)
        {
            if (!InScope(tenantId, schoolId)) return new();
            var ds = await Db.ExecuteProcedureWithCursorsAsync(proc, p.ToArray());
            return CursorRows.From(ds.Tables.Count > 0 ? ds.Tables[0] : null);
        }

        /// <summary>A write: the procedure's message, or its RAISE text when it refuses.</summary>
        protected async Task<(bool Success, string Message)> WriteAsync(string proc, List<NpgsqlParameter> p, int tenantId, int schoolId)
        {
            if (!InScope(tenantId, schoolId)) return (false, "Invalid request.");
            try
            {
                var ds = await Db.ExecuteProcedureWithCursorsAsync(proc, p.ToArray());
                var msg = ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0 && ds.Tables[0].Columns.Contains("message")
                    ? ds.Tables[0].Rows[0]["message"]?.ToString() : null;
                return (true, msg ?? "Saved.");
            }
            catch (PostgresException pex)
            {
                Logger.LogWarning(pex, "{Proc} refused for school {SchoolId}. SqlState {SqlState}", proc, schoolId, pex.SqlState);
                return (false, pex.MessageText);
            }
            catch (Exception ex)
            {
                Logger.LogError(ex, "{Proc} failed for school {SchoolId}.", proc, schoolId);
                return (false, "Could not save. Please try again.");
            }
        }
    }
}
