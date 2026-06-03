using Microsoft.AspNetCore.Mvc;

namespace educore.Controllers
{
    public class DashboardsController : Controller
    {
        public IActionResult Index()
        {
            return View();
        }
    }
}
