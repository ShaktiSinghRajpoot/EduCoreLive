using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class StudentController : Controller
    {
        public IActionResult StudentList()
        {
            return View();
        }

        public IActionResult Dashboard(int id = 0)
        {
            ViewBag.StudentId = id;
            return View();
        }

        public IActionResult EditStudent(int id = 0)
        {
            ViewBag.StudentId = id;
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult EditStudent(int id, IFormCollection form)
        {
            // Replace with real service call once SP is ready
            TempData["SuccessMessage"] = "Student profile updated successfully.";
            return RedirectToAction("Dashboard", new { id });
        }

        public IActionResult StudentAttendance()
        {
            return View();
        }
    }
}
