using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;
using System.Data;

public class RolePermissionService : IRolePermissionService
{
    private readonly PgExec _db;

    public RolePermissionService(PgExec db)
    {
        _db = db;
    }

    public async Task<List<RolePermissionDto>> GetRolePermissionsAsync(int tenantId, int schoolId, int roleId)
    {
        var parameters = new NpgsqlParameter[]
        {
            new NpgsqlParameter("p_operation_type", "GET_ROLE_PERMISSIONS"),
            new NpgsqlParameter("p_tenant_id", tenantId),
            new NpgsqlParameter("p_school_id", schoolId),
            new NpgsqlParameter("p_role_id", roleId),
            new NpgsqlParameter("p_permission_ids", NpgsqlDbType.Array | NpgsqlDbType.Integer) { Value = DBNull.Value },
            new NpgsqlParameter("p_action_by", DBNull.Value),
            new NpgsqlParameter("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "permission_cursor" }
        };

        var dal = _db;
        var ds = await dal.ExecuteProcedureWithCursorsAsync(
            "config.sp_role_permission_management",
            parameters
        );

        if (ds.Tables.Count == 0)
            return new List<RolePermissionDto>();

        return ds.Tables[0]
            .AsEnumerable()
            .Select(BindRolePermission)
            .ToList();
    }

    private static RolePermissionDto BindRolePermission(DataRow row)
    {
        return new RolePermissionDto
        {
            PermissionId = Convert.ToInt32(row["permission_id"]),
            PermissionKey = row["permission_key"]?.ToString() ?? "",
            PermissionName = row["permission_name"]?.ToString() ?? "",
            ModuleName = row["module_name"]?.ToString() ?? "",
            IsSelected = row.Table.Columns.Contains("is_selected")
                         && row["is_selected"] != DBNull.Value
                         && Convert.ToBoolean(row["is_selected"])
        };
    }
}