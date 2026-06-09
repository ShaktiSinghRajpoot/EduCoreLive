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
         
        public IActionResult StudentList()
        {
            return View();
        }

        public IActionResult Promotion()
        {
            return View();
        }

        public IActionResult Inactive()
        {
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult Reactivate(int id)
        {
            // Replace with real service call once the SP is ready.
            TempData["SuccessMessage"] = "Student re-activated successfully.";
            return RedirectToAction("Inactive");
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult Promotion(IFormCollection form)
        {
            // Replace with real service call once the promote SP is ready.
            // Expected payload: source year/class/section, target year/class/section,
            // per-student outcome (promote/retain/passout), carry-forward-dues flag.
            TempData["SuccessMessage"] = "Students promoted successfully.";
            return RedirectToAction("Promotion");
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
    }
}
