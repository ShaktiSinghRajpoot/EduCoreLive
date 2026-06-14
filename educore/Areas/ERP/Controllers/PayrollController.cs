using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class PayrollController : Controller
    {
        public IActionResult PayrollManagement()
        {
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult MarkPaid(int id)
        {
            // Replace with real service call once the SP is ready.
            // Persists the computed payslip row and flips status to Paid.
            TempData["SuccessMessage"] = "Payslip marked as paid.";
            return RedirectToAction("PayrollManagement");
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public IActionResult RunPayroll(IFormCollection form)
        {
            // Replace with real service call once the SP is ready.
            // Expected payload: month, department. Generates payslip rows for the period.
            TempData["SuccessMessage"] = "Payroll run completed for the selected period.";
            return RedirectToAction("PayrollManagement");
        }
    }
}
