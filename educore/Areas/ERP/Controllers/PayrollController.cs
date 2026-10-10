using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    // Salary has its own keys (payroll_permissions.sql): payroll.view to look,
    // payroll.manage for every write. staff.view alone no longer opens payroll.
    [HasPermission("payroll.view")]
    [RequiresModule(SchoolModule.Payroll)]
    public class PayrollController : Controller
    {
        private readonly IStaffPayrollService _payrollService;
        private readonly IStaffService _staffService;

        public PayrollController(IStaffPayrollService payrollService, IStaffService staffService)
        {
            _payrollService = payrollService;
            _staffService = staffService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        public async Task<IActionResult> PayrollManagement()
        {
            // The month picker was three hardcoded options. Offer the last twelve
            // months, newest first — payroll is never run for a future month (the
            // proc refuses one too).
            var months = Enumerable.Range(0, 12)
                .Select(i => Dates.Now.Date.AddMonths(-i))
                .Select(d => new { value = $"{d:yyyy-MM}", label = d.ToString("MMMM yyyy") })
                .ToList();
            ViewBag.Months = months;

            // Department filter from the school's own masters (it was a hardcoded
            // list whose names matched nothing the school had set up).
            var dd = await _staffService.GetDropdownsAsync(TenantId(), SchoolId());
            ViewBag.Departments = dd.Departments;

            // Staff an adjustment can be recorded for (leavers too: final settlement).
            ViewBag.Staff = (await _staffService.GetStaffAsync(TenantId(), SchoolId(), UserId()))
                .Select(s => new { id = s.StaffId, name = s.FullName + (string.IsNullOrWhiteSpace(s.EmployeeCode) ? "" : " · " + s.EmployeeCode) })
                .ToList();
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
                salary      = r.MonthlySalary,
                workingDays = r.WorkingDays,
                paidDays    = r.PaidDays,
                gross       = r.Gross,
                lopDays     = r.LopDays,
                lopAmount   = r.LopAmount,
                additions   = r.OtherAdd,
                otherDeduct = r.OtherDeduct,
                deductions  = r.TotalDeduct,
                net         = r.NetPay,
                status      = r.Status,
                paidAt      = r.PaidAt?.ToString("dd MMM yyyy HH:mm") ?? "",
                paidBy      = r.PaidByName ?? "",
                payMode     = r.PaymentMode ?? "",
                payRef      = r.PaymentReference ?? ""
            }));
        }

        // The money trail of one payslip: generated, regenerated, adjusted, paid.
        [HttpGet]
        public async Task<IActionResult> History(int id)
        {
            var rows = await _payrollService.GetHistoryAsync(id, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(h => new
            {
                action = h.Action, net = h.NetPay, mode = h.PaymentMode ?? "", reference = h.PaymentReference ?? "",
                note = h.Note ?? "", at = h.ActionAt?.ToString("dd MMM yyyy HH:mm") ?? "", by = h.ActionByName ?? ""
            }));
        }

        [HttpGet]
        public async Task<IActionResult> Adjustments(int month, int year)
        {
            var rows = await _payrollService.GetAdjustmentsAsync(month, year, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(a => new
            {
                id = a.AdjustmentId, staffId = a.StaffId, name = a.FullName, code = a.EmployeeCode ?? "",
                kind = a.Kind, amount = a.Amount, reason = a.Reason,
                mode = a.PaymentMode ?? "", reference = a.PaymentReference ?? "",
                at = a.CreatedAt?.ToString("dd MMM yyyy") ?? "", by = a.CreatedByName ?? "",
                isVoid = a.IsVoid, voidReason = a.VoidReason ?? ""
            }));
        }

        [HttpPost]
        [HasPermission("payroll.manage")]
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
        [HasPermission("payroll.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> MarkPaid(int id, string? paymentMode, string? paymentReference)
        {
            var result = await _payrollService.MarkPaidAsync(id, paymentMode, paymentReference,
                                                             TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [HasPermission("payroll.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> AddAdjustment(int staffId, int month, int year, string? kind, decimal amount,
                                                       string? reason, string? paymentMode, string? paymentReference)
        {
            var result = await _payrollService.AddAdjustmentAsync(staffId, month, year, kind, amount, reason,
                                                                  paymentMode, paymentReference,
                                                                  TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [HasPermission("payroll.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> VoidAdjustment(int id, string? reason)
        {
            var result = await _payrollService.VoidAdjustmentAsync(id, reason, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }
    }
}
