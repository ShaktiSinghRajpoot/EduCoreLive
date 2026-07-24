using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
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
