using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    [HasPermission("fees.view")]
    public class FeeDueRemindersController : Controller
    {
        [HttpGet]
        public IActionResult Index()
        {
            return View();
        }
    }
}
