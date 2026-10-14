using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Front office: visitors, calls, complaints (front_office.sql).</summary>
    public interface IFrontOfficeService
    {
        /// <summary>operation = Summary | Visitors | Calls | Complaints; from / to yyyy-MM-dd; status for complaints.</summary>
        Task<List<Dictionary<string, object?>>> ListAsync(string operation, string? from, string? to, string? status,
                                                         int tenantId, int schoolId, int actionUserId);

        /// <summary>operation = VisitorSave | VisitorOut | CallSave | CallDone | ComplaintSave | ComplaintStatus.</summary>
        Task<(bool Success, string Message)> SaveAsync(string operation, FrontOfficeEntry e, int tenantId, int schoolId, int actionUserId);
    }
}
