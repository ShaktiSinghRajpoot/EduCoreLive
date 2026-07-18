using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    [HasPermission("fees.view")]
    public class PaymentVerificationController : Controller
    {
        [HttpGet]
        public IActionResult Index()
        {
            return View();
        }
    }
}
