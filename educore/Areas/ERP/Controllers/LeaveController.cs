using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class LeaveController : Controller
    {
        public IActionResult LeaveManagement()
        {
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult ApplyLeave(IFormCollection form)
        {
            // Replace with real service call once the SP is ready.
            // Expected payload: staffId, leaveType, fromDate, toDate, reason.
            TempData["SuccessMessage"] = "Leave application submitted successfully.";
            return RedirectToAction("LeaveManagement");
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult Approve(int id)
        {
            // Replace with real service call once the SP is ready.
            TempData["SuccessMessage"] = "Leave request approved.";
            return RedirectToAction("LeaveManagement");
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult Reject(int id)
        {
            // Replace with real service call once the SP is ready.
            TempData["SuccessMessage"] = "Leave request rejected.";
            return RedirectToAction("LeaveManagement");
        }
    }
}
