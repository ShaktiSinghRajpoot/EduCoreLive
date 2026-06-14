using EduCoreDataAccessLayer.Models.Admin;

namespace EduCoreDataAccessLayer.Services.Contract.Admin
{
    /// <summary>
    /// Registration Register — lists registered students with their numbers/details
    /// and supports cancel / mark-fee-collected actions.
    /// </summary>
    public interface IRegistrationService
    {
        Task<(List<RegistrationListItem> Items, int TotalCount)> GetRegistrationsAsync(
            int tenantId, int schoolId, int actionUserId,
            int pageNumber = 1, int pageSize = 10,
            string? search = null, string? session = null,
            string? className = null, string? feeStatus = null);

        Task<RegistrationStats> GetStatsAsync(int tenantId, int schoolId, int actionUserId);

        Task<(int Success, string Message)> CancelRegistrationAsync(
            int enquiryId, string? reason, int tenantId, int schoolId, int actionUserId);

        Task<(int Success, string Message)> MarkFeePaidAsync(
            int enquiryId, int tenantId, int schoolId, int actionUserId);
    }
}
