using EduCoreDataAccessLayer.Models.Admin;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    /// <summary>
    /// Reads and persists the per-school Admission Workflow settings.
    /// Kept as a dedicated service (not folded into SchoolSettings) so the
    /// admission workflow hub can grow — Document Verification, Entrance Test,
    /// Interview, Approvals — without bloating the settings service.
    /// </summary>
    public interface IAdmissionWorkflowService
    {
        Task<AdmissionWorkflowModel> GetAdmissionWorkflowAsync(int tenantId, int schoolId, int actionUserId);
        Task<int> SaveAdmissionWorkflowAsync(AdmissionWorkflowModel model, int tenantId, int schoolId, int actionUserId);
    }
}
