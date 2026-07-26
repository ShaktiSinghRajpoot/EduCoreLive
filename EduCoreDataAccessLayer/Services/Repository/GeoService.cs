using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services.Contract;
using educore.Services;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Services.Repository
{
    /// <summary>
    /// Country/State/District lookups from config.sp_geo_lookup. The proc uses the
    /// same p_activity/p_param1/p_param2/p_result shape as config.sp_dropdown_common,
    /// so IBaseService.GetSelectListAsync maps it with no extra plumbing.
    ///
    /// Cache keys are GLOBAL, not AppCache.Key(name, tenantId, schoolId): geography
    /// is platform reference data with no tenant dimension, so a tenant-scoped key
    /// would just cache 500 identical copies of the same 36 states. Long TTL — these
    /// rows change when a state creates a district, i.e. roughly never.
    /// </summary>
    public class GeoService : IGeoService
    {
        private const string Proc = "config.sp_geo_lookup";
        private static readonly TimeSpan Ttl = TimeSpan.FromHours(12);

        private readonly IBaseService _base;
        private readonly AppCache _cache;

        public GeoService(IBaseService baseService, AppCache cache)
        {
            _base = baseService;
            _cache = cache;
        }

        public Task<List<SelectListItem>> GetCountriesAsync() =>
            _cache.GetOrCreateAsync("geo:countries",
                () => _base.GetSelectListAsync(Proc, "Country"), Ttl);

        public Task<List<SelectListItem>> GetStatesAsync(int? countryId = null)
        {
            var key = countryId.GetValueOrDefault() > 0 ? $"geo:states:{countryId}" : "geo:states:default";
            return _cache.GetOrCreateAsync(key,
                () => _base.GetSelectListAsync(Proc, "State", countryId.GetValueOrDefault() > 0 ? countryId!.Value.ToString() : ""), Ttl);
        }

        public Task<List<SelectListItem>> GetDistrictsAsync(int stateId)
        {
            if (stateId <= 0)
                return Task.FromResult(new List<SelectListItem>());

            return _cache.GetOrCreateAsync($"geo:districts:{stateId}",
                () => _base.GetSelectListAsync(Proc, "District", stateId.ToString()), Ttl);
        }

        public async Task<int> GetDefaultCountryIdAsync()
        {
            // The proc orders countries by display_order, and India is seeded at 1.
            var countries = await GetCountriesAsync();
            var first = countries.FirstOrDefault();
            return first != null && int.TryParse(first.Value, out var id) ? id : 0;
        }
    }
}
