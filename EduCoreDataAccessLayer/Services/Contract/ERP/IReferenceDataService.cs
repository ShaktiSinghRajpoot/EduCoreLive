using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>
    /// Single entry point for reference / lookup dropdown data. Every screen's
    /// enumerated dropdowns (payment mode, enquiry source/status, fee cycle,
    /// gender, exam type, ...) resolve through here instead of hard-coded
    /// &lt;option&gt; lists — ONE source of truth.
    ///
    /// Backed by config.sp_dropdown_common (entity masters + the generic
    /// config.lookup_value table) and cached per tenant/school via AppCache.
    /// After editing a lookup list, call <see cref="Invalidate"/> so the next
    /// read refreshes.
    /// </summary>
    public interface IReferenceDataService
    {
        /// <summary>Options for a category (e.g. "PaymentMode"), scoped to the school.</summary>
        Task<List<SelectListItem>> GetOptionsAsync(string category, int tenantId, int schoolId);

        /// <summary>Drop the cached options for a category after a lookup edit.</summary>
        void Invalidate(string category, int tenantId, int schoolId);
    }
}
