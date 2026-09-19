using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("staff.view")]
    public class PayrollController : Controller
    {
        private readonly IStaffPayrollService _payrollService;

        public PayrollController(IStaffPayrollService payrollService)
        {
            _payrollService = payrollService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        public IActionResult PayrollManagement()
        {
            // The month picker was three hardcoded options. Offer the last twelve
            // months, newest first — payroll is never run for a future month.
            var months = Enumerable.Range(0, 12)
                .Select(i => DateTime.Today.AddMonths(-i))
                .Select(d => new { value = $"{d:yyyy-MM}", label = d.ToString("MMMM yyyy") })
                .ToList();

            ViewBag.Months = months;
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> List(int month, int year, string? department = null)
        {
            var rows = await _payrollService.GetPayrollAsync(
                month, year, TenantId(), SchoolId(), UserId(), department);

            return Json(rows.Select(r => new
            {
                id          = r.PayrollId,
                staffId     = r.StaffId,
                name        = r.FullName,
                code        = r.EmployeeCode ?? "",
                designation = r.Designation ?? "",
                department  = r.Department ?? "",
                gross       = r.Gross,
                lopDays     = r.LopDays,
                lopAmount   = r.LopAmount,
                deductions  = r.TotalDeduct,
                net         = r.NetPay,
                status      = r.Status,
                paidAt      = r.PaidAt?.ToString("dd MMM yyyy") ?? ""
            }));
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> RunPayroll(int month, int year)
        {
            var result = await _payrollService.RunAsync(month, year, TenantId(), SchoolId(), UserId());

            return Json(new
            {
                success     = result.Success,
                message     = result.Message,
                generated   = result.Generated,
                skipped     = result.Skipped,
                workingDays = result.WorkingDays
            });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> MarkPaid(int id)
        {
            var result = await _payrollService.MarkPaidAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }
    }
}
