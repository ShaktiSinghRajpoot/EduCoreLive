using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class StudentController : Controller
    {
        
        public IActionResult StudentAttendance()
        {
            return View();
        }
    }
}
