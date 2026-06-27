using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using Npgsql;
using NpgsqlTypes;
using System.Data;

namespace EduCoreDataAccessLayer.Services
{
    /// <summary>
    /// Runtime permission resolution for the dynamic RBAC system — resolved per USER.
    ///
    /// A user may hold several roles; their effective permissions are the UNION of all
    /// of them ("add them up", no role-switching). If ANY of the user's roles is an
    /// admin role (SUPER_ADMIN / SCHOOL_ADMIN) the user bypasses all checks.
    ///
    /// Two small caches keep this cheap and correctly invalidatable:
    ///   • the user's role list  → key "uroles:u{userId}"  (invalidated when their roles change)
    ///   • each role's perm keys → key "rperms:r{roleId}"  (invalidated when that role's matrix is saved)
    /// The per-request union over a handful of roles is negligible, so the final set is
    /// not cached — which means a matrix edit takes effect immediately for every user.
    ///
    /// "x.manage" implies "x.view" (a manager can also read).
    /// </summary>
    public interface IPermissionService
    {
        Task<bool> HasPermissionAsync(int tenantId, int schoolId, int userId, string permissionKey, int activeRoleId = 0);

        /// <summary>
        /// The user's effective access: whether they're an admin (full bypass) and their permission key set.
        /// When <paramref name="activeRoleId"/> is a role the user actually holds, access is narrowed to JUST
        /// that role ("focus / viewing as"); otherwise it's the UNION of all the user's roles (combined view).
        /// </summary>
        Task<(bool IsAdmin, HashSet<string> Keys)> GetUserAccessAsync(int tenantId, int schoolId, int userId, int activeRoleId = 0);

        /// <summary>The roles this user holds in this school, for the "switch role" UI (id + friendly display name).</summary>
        Task<List<(int RoleId, string RoleName)>> GetUserRolesListAsync(int tenantId, int schoolId, int userId);

        void InvalidateRole(int tenantId, int schoolId, int roleId);
        void InvalidateUser(int tenantId, int schoolId, int userId);
    }

    public class PermissionService : IPermissionService
    {
        private readonly PgExec _db;
        private readonly AppCache _cache;

        private const string SpUserRoles = "core.sp_user_roles_resolve";
        private const string SpResolve   = "config.sp_role_permissions_resolve";

        public PermissionService(PgExec db, AppCache cache)
        {
            _db = db;
            _cache = cache;
        }

        public async Task<bool> HasPermissionAsync(int tenantId, int schoolId, int userId, string permissionKey, int activeRoleId = 0)
        {
            if (string.IsNullOrWhiteSpace(permissionKey)) return false;
            var (isAdmin, keys) = await GetUserAccessAsync(tenantId, schoolId, userId, activeRoleId);
            return isAdmin || keys.Contains(permissionKey);
        }

        public async Task<(bool IsAdmin, HashSet<string> Keys)> GetUserAccessAsync(int tenantId, int schoolId, int userId, int activeRoleId = 0)
        {
            var empty = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (tenantId <= 1 || schoolId <= 0 || userId <= 0) return (false, empty);

            var roles = await GetUserRolesAsync(tenantId, schoolId, userId);

            // Focus / "viewing as": if the user picked one of their own roles, act as just that
            // role. A stale/foreign selection is ignored → falls back to the combined view.
            if (activeRoleId > 0 && roles.Any(r => r.RoleId == activeRoleId))
                roles = roles.Where(r => r.RoleId == activeRoleId).ToList();

            // Admin role in the (possibly narrowed) set → full bypass, no permission lookup needed.
            if (roles.Any(r => IsAdminCode(r.RoleCode)))
                return (true, empty);

            // Union the permission keys of every role in the (possibly narrowed) set.
            var union = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in roles)
                union.UnionWith(await GetRoleKeysAsync(tenantId, schoolId, r.RoleId));

            return (false, union);
        }

        public async Task<List<(int RoleId, string RoleName)>> GetUserRolesListAsync(int tenantId, int schoolId, int userId)
        {
            if (tenantId <= 1 || schoolId <= 0 || userId <= 0)
                return new List<(int, string)>();

            var roles = await GetUserRolesAsync(tenantId, schoolId, userId);
            return roles.Select(r => (r.RoleId, FriendlyRoleName(r.RoleCode))).ToList();
        }

        // role_code is auto-generated from the role name (UPPER + non-alnum→_); turn it back into
        // a readable label, e.g. ACCOUNTANT → "Accountant", FRONT_DESK → "Front Desk".
        private static string FriendlyRoleName(string? code)
        {
            if (string.IsNullOrWhiteSpace(code)) return "Role";
            var words = code.Replace('_', ' ').ToLowerInvariant()
                            .Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return string.Join(' ', words.Select(w => char.ToUpperInvariant(w[0]) + w[1..]));
        }

        public void InvalidateRole(int tenantId, int schoolId, int roleId) =>
            _cache.Remove(AppCache.Key($"rperms:r{roleId}", tenantId, schoolId));

        public void InvalidateUser(int tenantId, int schoolId, int userId) =>
            _cache.Remove(AppCache.Key($"uroles:u{userId}", tenantId, schoolId));

        // ── helpers ──────────────────────────────────────────────────────────
        private static bool IsAdminCode(string? roleCode) =>
            string.Equals(roleCode, AppRoles.SuperAdmin, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(roleCode, AppRoles.SchoolAdmin, StringComparison.OrdinalIgnoreCase);

        private Task<List<(int RoleId, string? RoleCode)>> GetUserRolesAsync(int tenantId, int schoolId, int userId) =>
            _cache.GetOrCreateAsync(AppCache.Key($"uroles:u{userId}", tenantId, schoolId), async () =>
            {
                var list = new List<(int, string?)>();
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    SpUserRoles,
                    new NpgsqlParameter[]
                    {
                        new("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                        new("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                        new("p_user_id",   NpgsqlDbType.Integer) { Value = userId },
                        new("p_result",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "user_roles_cursor" }
                    });
                if (ds.Tables.Count > 0)
                    foreach (DataRow r in ds.Tables[0].Rows)
                        list.Add((Convert.ToInt32(r["role_id"]), r["role_code"]?.ToString()));
                return list;
            });

        private Task<HashSet<string>> GetRoleKeysAsync(int tenantId, int schoolId, int roleId) =>
            _cache.GetOrCreateAsync(AppCache.Key($"rperms:r{roleId}", tenantId, schoolId), async () =>
            {
                var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var ds = await _db.ExecuteProcedureWithCursorsAsync(
                    SpResolve,
                    new NpgsqlParameter[]
                    {
                        new("p_tenant_id", NpgsqlDbType.Integer) { Value = tenantId },
                        new("p_school_id", NpgsqlDbType.Integer) { Value = schoolId },
                        new("p_role_id",   NpgsqlDbType.Integer) { Value = roleId },
                        new("p_result",    NpgsqlDbType.Refcursor) { Direction = ParameterDirection.InputOutput, Value = "resolve_cursor" }
                    });
                if (ds.Tables.Count > 0)
                {
                    foreach (DataRow r in ds.Tables[0].Rows)
                    {
                        var k = r["permission_key"]?.ToString();
                        if (string.IsNullOrWhiteSpace(k)) continue;
                        set.Add(k);
                        if (k.EndsWith(".manage", StringComparison.OrdinalIgnoreCase))
                            set.Add(k[..^".manage".Length] + ".view");
                    }
                }
                return set;
            });
    }
}
