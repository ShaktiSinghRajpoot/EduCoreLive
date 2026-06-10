using System.Security.Claims;
using System.Threading.Tasks;
using educore.Models;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Mvc;

namespace educore.ViewComponents
{
    // Renders the logged-in school's identity (logo/initials, name, address) for the
    // top bar. Self-fetching so the shared navbar partial doesn't depend on every
    // controller passing the data down. School id/tenant come from the auth claims.
    public class SchoolIdentityViewComponent : ViewComponent
    {
        private readonly ISchoolSettingsService _schoolSettingsService;

        public SchoolIdentityViewComponent(ISchoolSettingsService schoolSettingsService)
        {
            _schoolSettingsService = schoolSettingsService;
        }

        public async Task<IViewComponentResult> InvokeAsync()
        {
            int tenantId = ToInt(UserClaimsPrincipal.FindFirst(Common.SK_TenantId)?.Value);
            int schoolId = ToInt(UserClaimsPrincipal.FindFirst(Common.SK_SchoolId)?.Value);
            int userId   = ToInt(UserClaimsPrincipal.FindFirst(Common.SK_UserId)?.Value);

            SchoolManageModel? model = null;
            if (schoolId > 0)
            {
                model = await _schoolSettingsService.GetBasicProfileAsync(tenantId, schoolId, userId);
            }

            return View(model);
        }

        private static int ToInt(string? value) =>
            int.TryParse(value, out var result) ? result : 0;
    }
}
