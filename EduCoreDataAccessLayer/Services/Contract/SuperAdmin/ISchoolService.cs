using educore.Models;

namespace EduCoreDataAccessLayer.Services.Contract.SuperAdmin
{
    public interface ISchoolService
    {
        Task<List<SchoolListModel>> GetSchoolsAsync(int tenantId, int actionUserId);
        Task<int> CreateSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId);
        Task<int> SaveSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId);
        Task<SchoolManageModel?> GetSchoolByIdAsync(int schoolId, int tenantId, int actionUserId);
        Task DeleteSchoolAsync(int schoolId, int tenantId, int actionUserId);
        Task<SchoolDropdownModel> GetSchoolDropdownsAsync();
    }
}
