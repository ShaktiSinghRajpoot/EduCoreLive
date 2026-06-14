using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class StaffController : Controller
    {
        public IActionResult StaffList()
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
            TempData["SuccessMessage"] = "Staff member re-activated successfully.";
            return RedirectToAction("Inactive");
        }

        public IActionResult AddStaff()
        {
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult AddStaff(IFormCollection form)
        {
            // Replace with real service call once the SP is ready.
            // Expected payload: personal, employment (designation/department/join date),
            // qualification, and bank/payroll fields.
            TempData["SuccessMessage"] = "Staff member added successfully.";
            return RedirectToAction("StaffList");
        }

        public IActionResult StaffProfile(int id = 0)
        {
            ViewBag.StaffId = id;
            return View();
        }

        public IActionResult EditStaff(int id = 0)
        {
            ViewBag.StaffId = id;
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult EditStaff(int id, IFormCollection form)
        {
            // Replace with real service call once SP is ready.
            TempData["SuccessMessage"] = "Staff profile updated successfully.";
            return RedirectToAction("StaffProfile", new { id });
        }
    }
}
