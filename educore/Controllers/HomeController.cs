using EduCoreDataAccessLayer.Helpers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using System.Security.Claims;

namespace educore.Controllers
{
    [Authorize]
    public class HomeController : Controller
    {
        public IActionResult Dashboard()
        {
            var roleCode = User.FindFirst(ClaimTypes.Role)?.Value;

            return roleCode switch
            {
                AppRoles.SuperAdmin => RedirectToAction("SchoolList", "Schools", new { area = "SuperAdmin" }),
                AppRoles.SchoolAdmin => RedirectToAction("BasicProfile", "SchoolSettings", new { area = "Admin" }),
                _ => RedirectToAction("Login", "Account", new { area = "" })
            };
        }
    }
}
