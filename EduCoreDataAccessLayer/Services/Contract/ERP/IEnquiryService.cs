using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    public interface IEnquiryService
    {
        // Page load — fills Items + TotalCount + KPI on the bound query model.
        Task<EnquiryCrmPageModel> GetEnquiryCrmPageAsync(
            EnquiryCrmPageModel query, int tenantId, int schoolId, int actionUserId);

        // Server-side filtered + paginated list
        Task<(List<EnquiryListModel> Items, int TotalCount)> GetEnquiriesAsync(
            int     tenantId,
            int     schoolId,
            int     actionUserId,
            int     pageNumber      = 1,
            int     pageSize        = 10,
            string? search          = null,
            string? filterSession   = null,
            string? filterPriority  = null,
            string? filterClass     = null,
            string? filterSource    = null,
            string? filterPipeline  = null,
            int?    filterAssignedTo = null,
            bool    filterOverdue   = false,
            bool    filterToday     = false,
            string? sortColumn      = null,
            string? sortDir         = "asc");

        Task<EnquiryStatsModel>  GetKpiStatsAsync(int tenantId, int schoolId, int actionUserId);
        Task<EnquiryModel?>      GetEnquiryByIdAsync(int enquiryId, int tenantId, int schoolId, int actionUserId);

        // Save / update (full form)
        Task<int> SaveEnquiryAsync(EnquiryModel model, int tenantId, int schoolId, int actionUserId);

        // Status-only AJAX update (auto-logs to status_history)
        Task<(int Success, string Message)> UpdateStatusAsync(
            int enquiryId, string status, string? lostReason,
            int tenantId, int schoolId, int actionUserId);

        // Register an enquiry — issues a registration number, records date/fee,
        // and moves the lead to "Registration Done".
        Task<(int Success, string Message, string? RegistrationNumber)> RegisterEnquiryAsync(
            int       enquiryId,
            string?   registrationNumber,
            DateOnly? registrationDate,
            bool      registrationFeePaid,
            bool      autoGenerate,
            string?   prefix,
            int       tenantId,
            int       schoolId,
            int       actionUserId);

        // Follow-up log (records interaction + optionally changes status)
        Task<int> LogFollowupAsync(
            int      enquiryId,
            string   followupType,
            string?  outcome,
            string?  notes,
            DateOnly? nextFollowupDate,
            string?  newStatus,
            string?  lostReason,
            int      tenantId,
            int      schoolId,
            int      actionUserId);

        // Follow-up + status history
        Task<List<EnquiryFollowupModel>>       GetFollowupsAsync(int enquiryId, int tenantId, int schoolId, int actionUserId);
        Task<List<EnquiryStatusHistoryModel>>  GetStatusHistoryAsync(int enquiryId, int tenantId, int schoolId, int actionUserId);

        Task<int> DeleteEnquiryAsync(int enquiryId, int tenantId, int schoolId, int actionUserId);
    }
}
