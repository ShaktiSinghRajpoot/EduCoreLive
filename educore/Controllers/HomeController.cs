using EduCoreDataAccessLayer.Helpers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using System.Security.Claims;

namespace educore.Controllers
{
    [Authorize]
    public class HomeController : Controller
    {
        /// <summary>
        /// What is planned but not built. The side menu used to carry ~39 dimmed
        /// "soon" stubs across 17 groups, which made navigation look far bigger
        /// and more complicated than the working product. The roadmap lives here
        /// instead, so the menu only ever shows screens that work.
        /// </summary>
        public IActionResult Roadmap() => View();

        public IActionResult Dashboard()
        {
            var roleCode = User.FindFirst(ClaimTypes.Role)?.Value;

            return roleCode switch
            {
                AppRoles.SuperAdmin => RedirectToAction("SchoolList", "Schools", new { area = "SuperAdmin" }),
                AppRoles.SchoolAdmin => RedirectToAction("BasicProfile", "SchoolSettings", new { area = "ERP" }),
                _ => RedirectToAction("Login", "Account", new { area = "" })
            };
        }
    }
}
