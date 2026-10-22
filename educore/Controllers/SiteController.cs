using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Controllers
{
    /// <summary>
    /// The public website at smartschoolwala.com ("/"). A visitor sees the product
    /// page and its Login button opens the portal (/Account/Login). Someone already
    /// signed in goes straight to their dashboard, as "/" did before.
    /// </summary>
    [AllowAnonymous]
    public class SiteController : Controller
    {
        [HttpGet("/")]
        public IActionResult Index()
        {
            if (User.Identity?.IsAuthenticated == true)
                return RedirectToAction("Index", "Dashboards", new { area = "" });

            return View();
        }
    }
}
