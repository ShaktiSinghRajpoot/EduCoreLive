using EduCoreDataAccessLayer.Models;

namespace EduCoreDataAccessLayer.Services.Contract.SuperAdmin
{
    /// <summary>Enquiries from the public website's demo form (website_enquiry.sql).</summary>
    public interface IWebsiteEnquiryService
    {
        /// <summary>Saves an enquiry from the website (no sign-in). Message is the refusal text when Success is false.</summary>
        Task<(bool Success, string Message)> SaveAsync(WebsiteEnquiry e, string? ipAddress);

        /// <summary>Super Admin list, newest first, new ones on top. statusFilter null = all.</summary>
        Task<List<WebsiteEnquiry>> GetListAsync(string? statusFilter, int tenantId, int actionUserId);

        /// <summary>How many are still New (the menu badge). Cached for a minute.</summary>
        Task<int> CountNewAsync(int tenantId, int actionUserId);

        Task<(bool Success, string Message)> SetStatusAsync(int enquiryId, string status, string? note, int tenantId, int actionUserId);
    }
}
