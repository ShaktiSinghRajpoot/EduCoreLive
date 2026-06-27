using EduCoreDataAccessLayer.Models;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    /// <summary>Management of roles, the role↔permission matrix, and user↔role assignment.</summary>
    public interface IRbacService
    {
        // Roles
        Task<List<RoleModel>> GetRolesAsync(int tenantId, int schoolId, int actionUserId);
        Task<RoleModel?> GetRoleByIdAsync(int roleId, int tenantId, int schoolId, int actionUserId);
        Task<(int RoleId, string Message)> SaveRoleAsync(RoleModel model, string operation, int tenantId, int schoolId, int actionUserId);
        Task<(int RoleId, string Message)> DeleteRoleAsync(int roleId, int tenantId, int schoolId, int actionUserId);

        // Permission matrix
        Task<RolePermissionMatrix?> GetMatrixAsync(int roleId, int tenantId, int schoolId, int actionUserId);
        Task<(bool Ok, string Message)> SavePermissionsAsync(int roleId, IEnumerable<int> permissionIds, int tenantId, int schoolId, int actionUserId);

        // Users
        Task<List<UserRoleItem>> GetUsersAsync(int tenantId, int schoolId);
        Task<List<RoleModel>> GetAssignableRolesAsync(int tenantId, int schoolId, int actionUserId);
        Task<(bool Ok, string Message)> AssignRoleAsync(int userId, int roleId, int tenantId, int schoolId, int actionUserId);
    }
}
