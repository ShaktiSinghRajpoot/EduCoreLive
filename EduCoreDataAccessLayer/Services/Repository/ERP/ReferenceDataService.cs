using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Services;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Services.Repository.ERP
{
    /// <summary>
    /// Reads reference/lookup dropdowns through the shared provider
    /// (config.sp_dropdown_common) and caches each list per tenant/school.
    /// Reuses IBaseService's cursor→SelectListItem mapping so there's still
    /// exactly one place that shapes dropdown rows.
    /// </summary>
    public class ReferenceDataService : IReferenceDataService
    {
        private const string Proc = "config.sp_dropdown_common";

        private readonly IBaseService _base;
        private readonly AppCache _cache;

        public ReferenceDataService(IBaseService baseService, AppCache cache)
        {
            _base = baseService;
            _cache = cache;
        }

        public Task<List<SelectListItem>> GetOptionsAsync(string category, int tenantId, int schoolId)
        {
            var key = AppCache.Key($"lookup:{category}", tenantId, schoolId);
            return _cache.GetOrCreateAsync(key, () =>
                _base.GetSelectListAsync(Proc, category, tenantId.ToString(), schoolId.ToString()));
        }

        public void Invalidate(string category, int tenantId, int schoolId)
            => _cache.Remove(AppCache.Key($"lookup:{category}", tenantId, schoolId));
    }
}
