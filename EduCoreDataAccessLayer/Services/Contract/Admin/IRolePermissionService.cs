using EduCoreDataAccessLayer.Models.Admin;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    public interface IRolePermissionService
    {
        Task<List<RolePermissionDto>> GetRolePermissionsAsync(
            int tenantId,
            int schoolId,
            int roleId
        );

        //Task<ServiceResult> SaveRolePermissionsAsync(
        //    SaveRolePermissionRequest request,
        //    int tenantId,
        //    int schoolId,
        //    int actionBy
        //);
    }
}
