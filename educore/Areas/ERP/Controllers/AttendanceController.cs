using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("attendance.view")]
    public class AttendanceController : Controller
    {
        public IActionResult StudentAttendance()
        {
            return View();
        }

        public IActionResult AttendanceReport() 
        {
            return View();
        }
    }
}
