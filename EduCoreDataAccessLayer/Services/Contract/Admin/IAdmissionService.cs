using EduCoreDataAccessLayer.Models.Admin;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    public interface IAdmissionService
    {
        // Save a new admission. Freezes the fee plan, generates the ledger,
        // writes audit, and (when EnquiryId is set) links + closes the enquiry.
        Task<AdmissionSaveResult> SaveAdmissionAsync(
            AdmissionModel model, int tenantId, int schoolId, int actionUserId,
            decimal concessionCap = 100000m);

        // Server-side filtered + paginated student list.
        Task<(List<StudentListModel> Items, int TotalCount)> GetStudentsAsync(
            int     tenantId,
            int     schoolId,
            int     actionUserId,
            int     pageNumber    = 1,
            int     pageSize      = 10,
            string? search        = null,
            string? filterClass   = null,
            string? filterSection = null,
            string? filterGender  = null,
            string? filterYear    = null,
            string? filterStatus  = null);

        Task<AdmissionModel?> GetStudentByIdAsync(int studentId, int tenantId, int schoolId, int actionUserId);

        Task<int> DeleteStudentAsync(int studentId, int tenantId, int schoolId, int actionUserId);
    }
}
