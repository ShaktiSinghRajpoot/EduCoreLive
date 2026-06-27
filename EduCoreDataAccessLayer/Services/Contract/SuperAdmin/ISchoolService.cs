using educore.Models;

namespace EduCoreDataAccessLayer.Services.Contract.SuperAdmin
{
    public interface ISchoolService
    {
        Task<(List<SchoolListModel> Rows, int TotalCount, int ActiveCount)> GetSchoolsAsync(
            int tenantId, int actionUserId,
            string? search, string? city, string? state,
            int? statusId, int? boardId, int? schoolTypeId,
            DateTime? fromDate, DateTime? toDate,
            int pageNo, int pageSize);
        Task<int> CreateSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId);
        Task<int> SaveSchoolAsync(SchoolManageModel model, int tenantId, int actionUserId);
        Task<SchoolManageModel?> GetSchoolByIdAsync(int schoolId, int tenantId, int actionUserId);
        Task DeleteSchoolAsync(int schoolId, int tenantId, int actionUserId);
        Task<SchoolDropdownModel> GetSchoolDropdownsAsync();
    }
}
