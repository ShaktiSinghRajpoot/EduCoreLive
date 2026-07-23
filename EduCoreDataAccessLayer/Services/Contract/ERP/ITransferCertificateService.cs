using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Transfer Certificate issue + register. Content is frozen at issue time so a
    /// reprint is identical; the proc enforces the dues gate and the reprint stamp.
    /// </summary>
    public interface ITransferCertificateService
    {
        /// <summary>Issue a TC for a student who has left. Dues must be clear (the proc blocks).</summary>
        Task<TcIssueResult> IssueAsync(TcIssueRequest request, int tenantId, int schoolId, int actionUserId);

        /// <summary>Read the frozen certificate for printing. Marks it printed, so the
        /// second and later serves come back with WasDuplicate = true.</summary>
        Task<TransferCertificate?> GetForPrintAsync(int tcId, int tenantId, int schoolId, int actionUserId);

        /// <summary>The issued-TC register: search + paging.</summary>
        Task<TcListModel> GetListAsync(TcListModel query, int tenantId, int schoolId, int actionUserId);

        /// <summary>Void a mistaken certificate (retires the number, frees a re-issue).</summary>
        Task<(bool Success, string Message)> VoidAsync(TcVoidRequest request, int tenantId, int schoolId, int actionUserId);
    }
}
