using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Services.Contract
{
    /// <summary>
    /// Single source of truth for Country / State / District dropdowns — school
    /// address, student address, staff address, enquiry, transport, anywhere an
    /// address is captured. Replaces the free-text state/city boxes that produced
    /// 'UP', 'uttarpradesh' and 'Uttar Pradesh' as three different states.
    ///
    /// NOT tenant-scoped, deliberately: geography is platform reference data
    /// (see EduCoreDataAccessLayer/Database/geo_master.sql), so these methods take
    /// no tenantId/schoolId and the cache keys are global.
    ///
    /// District is the lowest level stored as an id; city stays free text (India
    /// has ~4,000 towns but ~800 districts, and district is what board/TC forms
    /// ask for). <see cref="GetDistrictsAsync"/> doubles as the city typeahead source.
    /// </summary>
    public interface IGeoService
    {
        /// <summary>Active countries, India first.</summary>
        Task<List<SelectListItem>> GetCountriesAsync();

        /// <summary>States + union territories of a country. Null/0 = India.</summary>
        Task<List<SelectListItem>> GetStatesAsync(int? countryId = null);

        /// <summary>Districts of a state. Empty when <paramref name="stateId"/> is not set.</summary>
        Task<List<SelectListItem>> GetDistrictsAsync(int stateId);

        /// <summary>Id of the default country (India) — used to pre-select the country box.</summary>
        Task<int> GetDefaultCountryIdAsync();
    }
}
