using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Staff.Controllers
{
    /// <summary>
    /// "My Payslip" (/my-payslip) -- a member of staff's own payslips, and a
    /// printable view of one.
    ///
    /// No permission key on purpose (same as My Bus / My Leave): the procedure
    /// core.sp_staff_my_payslip only ever returns payslips of the staff row whose
    /// user_id is the signed-in user. Asking for anyone else's payslip id returns
    /// nothing, which this controller shows as "not found". The payment reference
    /// and who paid are never loaded here; the mode and date are.
    /// </summary>
    [Area("Staff")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class MyPayslipController : Controller
    {
        private readonly IStaffSelfService _self;
        private readonly IAdmissionWorkflowService _workflow;

        public MyPayslipController(IStaffSelfService self, IAdmissionWorkflowService workflow)
        {
            _self = self;
            _workflow = workflow;
        }

        [HttpGet("my-payslip")]
        public async Task<IActionResult> Index()
        {
            ViewBag.ModuleOff = !await PayrollOnAsync();
            if (ViewBag.ModuleOff)
            {
                ViewBag.Me = null;
                return View(new List<MyPayslip>());
            }
            ViewBag.Me = await _self.GetMeAsync(TenantId(), SchoolId(), UserId());
            return View(await _self.GetMyPayslipsAsync(TenantId(), SchoolId(), UserId()));
        }

        // One payslip, laid out for printing.
        [HttpGet]
        public async Task<IActionResult> Slip(int id)
        {
            if (!await PayrollOnAsync()) return RedirectToAction(nameof(Index));

            var slip = await _self.GetMyPayslipAsync(id, TenantId(), SchoolId(), UserId());
            if (slip == null) return NotFound();
            return View(slip);
        }

        // ── Helpers ──────────────────────────────────────────────
        private async Task<bool> PayrollOnAsync()
        {
            if (TenantId() <= 1 || SchoolId() <= 0) return false;
            var settings = await _workflow.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            return settings.EnablePayroll;
        }

        private int TenantId() => int.TryParse(User.FindFirst(Common.SK_TenantId)?.Value, out var v) ? v : 0;
        private int SchoolId() => int.TryParse(User.FindFirst(Common.SK_SchoolId)?.Value, out var v) ? v : 0;
        private int UserId()   => int.TryParse(User.FindFirst(Common.SK_UserId)?.Value, out var v) ? v : 0;
    }
}
