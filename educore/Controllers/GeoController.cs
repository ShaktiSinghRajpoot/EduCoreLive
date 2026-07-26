using EduCoreDataAccessLayer.Services.Contract;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Controllers
{
    /// <summary>
    /// Cascading Country → State → District options for any address form in the app
    /// (school, student, staff, enquiry, transport). Backs the shared
    /// Views/Shared/_StateDistrictCity.cshtml partial and its wwwroot/js/geo-cascade.js.
    ///
    /// [Authorize] only — no role/tenant filter: this is platform reference data with
    /// no tenant dimension, so there is nothing here one school could leak to another.
    /// </summary>
    [Authorize]
    [Route("Geo")]
    public class GeoController : Controller
    {
        private readonly IGeoService _geo;

        public GeoController(IGeoService geo) => _geo = geo;

        [HttpGet("Countries")]
        public async Task<IActionResult> Countries() =>
            Json(await _geo.GetCountriesAsync());

        [HttpGet("States")]
        public async Task<IActionResult> States(int? countryId) =>
            Json(await _geo.GetStatesAsync(countryId));

        [HttpGet("Districts")]
        public async Task<IActionResult> Districts(int stateId) =>
            Json(await _geo.GetDistrictsAsync(stateId));
    }
}
