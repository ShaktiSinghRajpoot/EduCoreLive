using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services.Repository.Admin
{
    public class RbacService : IRbacService
    {
        private readonly PgExec _db;
        private readonly ILogger<RbacService> _logger;

        private const string SpRole       = "config.sp_role_manage";
        private const string SpCatalog    = "config.sp_permission_catalog";
        private const string SpRpGet      = "config.sp_role_permissions_get";
        private const string SpRpSave     = "config.sp_role_permissions_save";
        private const string SpUserList   = "core.sp_user_role_list";
        private const string SpUserAssign = "core.sp_user_role_assign";

        public RbacService(PgExec db, ILogger<RbacService> logger)
        {
            _db = db;
            _logger = logger;
        }

        // ───────────────────────────────────────────────────────────── Roles
        public async Task<List<RoleModel>> GetRolesAsync(int tenantId, int schoolId, int actionUserId)
        {
            var items = new List<RoleModel>();
            if (tenantId <= 1 || schoolId <= 0) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpRole, RoleParams("LIST", tenantId, schoolId, actionUserId));

            if (ds.Tables.Count == 0) return items;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                items.Add(new RoleModel
                {
                    RoleId          = IntVal(r, "role_id"),
                    RoleCode        = NullStr(r, "role_code"),
                    RoleName        = Str(r, "role_name"),
                    Description     = NullStr(r, "description"),
                    IsActive        = BoolVal(r, "is_active"),
                    IsBuiltin       = BoolVal(r, "is_builtin"),
                    UserCount       = IntVal(r, "user_count"),
                    PermissionCount = IntVal(r, "permission_count")
                });
            }
            return items;
        }

        public async Task<RoleModel?> GetRoleByIdAsync(int roleId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || roleId <= 0) return null;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpRole, RoleParams("GET", tenantId, schoolId, actionUserId, roleId: roleId));

            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return null;
            var r = ds.Tables[0].Rows[0];
            return new RoleModel
            {
                RoleId      = IntVal(r, "role_id"),
                RoleCode    = NullStr(r, "role_code"),
                RoleName    = Str(r, "role_name"),
                Description = NullStr(r, "description"),
                IsActive    = BoolVal(r, "is_active"),
                IsBuiltin   = BoolVal(r, "is_builtin")
            };
        }

        public async Task<(int RoleId, string Message)> SaveRoleAsync(
            RoleModel model, string operation, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0) return (0, "Invalid request.");
            try
            {
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    SpRole, RoleParams(operation, tenantId, schoolId, actionUserId,
                        roleId: model.RoleId, roleName: model.RoleName, description: model.Description));
                var id = (ds.Tables.Count > 0 && ds.Tables[0].Rows.Count > 0)
                    ? IntVal(ds.Tables[0].Rows[0], "role_id") : 0;
                return (id, "Saved.");
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Role {Op} business-rule error (SqlState {State})", operation, ex.SqlState);
                return (0, ex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Role {Op} unexpected error", operation);
                return (0, "Could not save the role. Please try again.");
            }
        }

        public async Task<(int RoleId, string Message)> DeleteRoleAsync(int roleId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || roleId <= 0) return (0, "Invalid request.");
            try
            {
                await _db.ExecuteProcedureWithCursorsAsync(
                    SpRole, RoleParams("DELETE", tenantId, schoolId, actionUserId, roleId: roleId));
                return (roleId, "Role deleted.");
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "Role DELETE business-rule error (SqlState {State})", ex.SqlState);
                return (0, ex.MessageText);
            }
        }

        // ───────────────────────────────────────────────── Permission matrix
        public async Task<RolePermissionMatrix?> GetMatrixAsync(int roleId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || roleId <= 0) return null;

            var role = await GetRoleByIdAsync(roleId, tenantId, schoolId, actionUserId);
            if (role == null) return null;

            // 1) the global catalog
            var catalog = new List<PermissionItem>();
            var catDs = await _db.ExecuteProcedureWithCursorsAsync(
                SpCatalog,
                new NpgsqlParameter[]
                {
                    new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "perm_cursor" }
                });
            if (catDs.Tables.Count > 0)
                foreach (DataRow r in catDs.Tables[0].Rows)
                    catalog.Add(new PermissionItem
                    {
                        PermissionId  = IntVal(r, "permission_id"),
                        PermissionKey = Str(r, "permission_key"),
                        ModuleGroup   = Str(r, "module_group"),
                        DisplayName   = Str(r, "display_name"),
                        SortOrder     = IntVal(r, "sort_order")
                    });

            // 2) currently granted permission ids for this role
            var granted = new HashSet<int>();
            var gDs = await _db.ExecuteProcedureWithCursorsAsync(
                SpRpGet,
                new NpgsqlParameter[]
                {
                    Int("p_tenant_id", tenantId),
                    Int("p_school_id", schoolId),
                    Int("p_role_id", roleId),
                    new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "rp_cursor" }
                });
            if (gDs.Tables.Count > 0)
                foreach (DataRow r in gDs.Tables[0].Rows)
                    granted.Add(IntVal(r, "permission_id"));

            // 3) pivot catalog → groups of feature rows (View / Manage columns)
            var matrix = new RolePermissionMatrix { RoleId = roleId, RoleName = role.RoleName, IsBuiltin = role.IsBuiltin };
            foreach (var grp in catalog.GroupBy(c => c.ModuleGroup))
            {
                var mg = new MatrixGroup { GroupName = grp.Key };
                foreach (var feat in grp.GroupBy(c => c.Feature).OrderBy(f => f.Min(x => x.SortOrder)))
                {
                    var view   = feat.FirstOrDefault(x => x.Level == "view");
                    var manage = feat.FirstOrDefault(x => x.Level == "manage");
                    mg.Rows.Add(new MatrixFeatureRow
                    {
                        FeatureLabel  = feat.First().FeatureLabel,
                        ViewId        = view?.PermissionId,
                        ManageId      = manage?.PermissionId,
                        ViewGranted   = view   != null && granted.Contains(view.PermissionId),
                        ManageGranted = manage != null && granted.Contains(manage.PermissionId)
                    });
                }
                matrix.Groups.Add(mg);
            }
            return matrix;
        }

        public async Task<(bool Ok, string Message)> SavePermissionsAsync(
            int roleId, IEnumerable<int> permissionIds, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || roleId <= 0) return (false, "Invalid request.");
            try
            {
                var ids = permissionIds?.Distinct().ToArray() ?? Array.Empty<int>();
                var p = new NpgsqlParameter[]
                {
                    Int("p_tenant_id", tenantId),
                    Int("p_school_id", schoolId),
                    Int("p_action_user_id", actionUserId),
                    Int("p_role_id", roleId),
                    new("p_permission_ids", NpgsqlDbType.Array | NpgsqlDbType.Integer) { Value = ids },
                    new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "rp_save_cursor" }
                };
                await _db.ExecuteProcedureWithCursorsAsync(SpRpSave, p);
                return (true, "Permissions updated.");
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "SavePermissions business-rule error (SqlState {State})", ex.SqlState);
                return (false, ex.MessageText);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "SavePermissions unexpected error");
                return (false, "Could not save permissions. Please try again.");
            }
        }

        // ───────────────────────────────────────────────────────────── Users
        public async Task<List<UserRoleItem>> GetUsersAsync(int tenantId, int schoolId)
        {
            var items = new List<UserRoleItem>();
            if (tenantId <= 1 || schoolId <= 0) return items;

            var ds = await _db.ExecuteProcedureWithCursorsAsync(
                SpUserList,
                new NpgsqlParameter[]
                {
                    Int("p_tenant_id", tenantId),
                    Int("p_school_id", schoolId),
                    new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "user_role_cursor" }
                });

            if (ds.Tables.Count == 0) return items;
            foreach (DataRow r in ds.Tables[0].Rows)
            {
                items.Add(new UserRoleItem
                {
                    UserId   = IntVal(r, "user_id"),
                    Email    = NullStr(r, "email"),
                    FullName = Str(r, "full_name"),
                    Phone    = NullStr(r, "phone"),
                    RoleId   = NullIntVal(r, "role_id"),
                    RoleName = NullStr(r, "role_name"),
                    RoleCode = NullStr(r, "role_code")
                });
            }
            return items;
        }

        public Task<List<RoleModel>> GetAssignableRolesAsync(int tenantId, int schoolId, int actionUserId)
            => GetRolesAsync(tenantId, schoolId, actionUserId);

        public async Task<(bool Ok, string Message)> AssignRoleAsync(
            int userId, int roleId, int tenantId, int schoolId, int actionUserId)
        {
            if (tenantId <= 1 || schoolId <= 0 || userId <= 0 || roleId <= 0) return (false, "Invalid request.");
            try
            {
                var p = new NpgsqlParameter[]
                {
                    Int("p_tenant_id", tenantId),
                    Int("p_school_id", schoolId),
                    Int("p_action_user_id", actionUserId),
                    Int("p_user_id", userId),
                    Int("p_role_id", roleId),
                    new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "assign_cursor" }
                };
                await _db.ExecuteProcedureWithCursorsAsync(SpUserAssign, p);
                return (true, "Role updated.");
            }
            catch (PostgresException ex)
            {
                _logger.LogWarning(ex, "AssignRole business-rule error (SqlState {State})", ex.SqlState);
                return (false, ex.MessageText);
            }
        }

        // ── positional params for config.sp_role_manage ──
        private static NpgsqlParameter[] RoleParams(
            string operation, int tenantId, int schoolId, int actionUserId,
            int roleId = 0, string? roleName = null, string? description = null)
        {
            return new NpgsqlParameter[]
            {
                Txt("p_operation", operation),
                Int("p_tenant_id", tenantId),
                Int("p_school_id", schoolId),
                Int("p_action_user_id", actionUserId),
                NInt("p_role_id", roleId > 0 ? roleId : (int?)null),
                Txt("p_role_name", roleName),
                Txt("p_description", description),
                new("p_result", NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "role_cursor" }
            };
        }

        // ── param builders ──
        private static NpgsqlParameter Txt(string n, string? v) => new(n, NpgsqlDbType.Text) { Value = string.IsNullOrWhiteSpace(v) ? DBNull.Value : v };
        private static NpgsqlParameter Int(string n, int v) => new(n, NpgsqlDbType.Integer) { Value = v };
        private static NpgsqlParameter NInt(string n, int? v) => new(n, NpgsqlDbType.Integer) { Value = (object?)v ?? DBNull.Value };

        // ── DataRow read helpers ──
        private static bool Has(DataRow r, string c) => r.Table.Columns.Contains(c);
        private static int IntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : 0;
        private static int? NullIntVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? Convert.ToInt32(r[c]) : (int?)null;
        private static bool BoolVal(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value && Convert.ToBoolean(r[c]);
        private static string Str(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString()! : string.Empty;
        private static string? NullStr(DataRow r, string c) => Has(r, c) && r[c] != DBNull.Value ? r[c].ToString() : null;
    }
}
