using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// "My Leave" (/ERP/MyLeave) -- a member of staff's own leave balance and
    /// requests, and applying / cancelling for themselves.
    ///
    /// No permission key on purpose: having a staff record (staff.user_id = this
    /// user) IS the permission, and core.sp_staff_my_leave resolves the staff row
    /// from the user id on every call. No action takes a staff id, so nobody can
    /// act on someone else's leave. A request made here goes in as Pending and
    /// HR approves it on Leave Management like any other.
    ///
    /// Leave belongs to the Payroll module (LeaveController is gated on it too).
    /// The switch is checked here rather than with [RequiresModule], which
    /// redirects to a settings page a teacher cannot open.
    /// </summary>
    [Area("ERP")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class MyLeaveController : Controller
    {
        private readonly IStaffSelfService _self;
        private readonly IAdmissionWorkflowService _workflow;

        public MyLeaveController(IStaffSelfService self, IAdmissionWorkflowService workflow)
        {
            _self = self;
            _workflow = workflow;
        }

        [HttpGet]
        public async Task<IActionResult> Index()
        {
            ViewBag.ModuleOff = !await PayrollOnAsync();
            ViewBag.Me = ViewBag.ModuleOff ? null : await _self.GetMeAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> List()
        {
            if (!await PayrollOnAsync()) return Json(new { success = false, message = ModuleOffMessage });

            var rows = await _self.GetMyLeavesAsync(TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success = true,
                rows = rows.Select(r => new
                {
                    id          = r.LeaveId,
                    type        = r.LeaveType,
                    from        = Dates.Show(r.FromDate, "dd MMM yyyy"),
                    to          = Dates.Show(r.ToDate, "dd MMM yyyy"),
                    days        = r.Days,
                    halfDay     = r.HalfDay,
                    reason      = r.Reason ?? "",
                    status      = r.Status,
                    remark      = r.DecisionRemark ?? "",
                    applied     = r.AppliedAt?.ToString("dd MMM yyyy") ?? "",
                    appliedBy   = r.AppliedByName ?? "",
                    decided     = r.DecidedAt?.ToString("dd MMM yyyy") ?? "",
                    decidedBy   = r.DecidedByName ?? "",
                    cancelled   = r.CancelledAt?.ToString("dd MMM yyyy") ?? "",
                    cancelledBy = r.CancelledByName ?? "",
                    cancelReason = r.CancelReason ?? "",
                    canCancel   = r.CanCancel
                })
            });
        }

        // My balance per leave type for the year of the given date (default: this year).
        [HttpGet]
        public async Task<IActionResult> Balance(string? date = null)
        {
            if (!await PayrollOnAsync()) return Json(new object[0]);

            var rows = await _self.GetMyBalanceAsync(date, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(b => new
            {
                type = b.LeaveType, entitled = b.Entitled, taken = b.Taken,
                pending = b.Pending, remaining = b.Remaining, year = b.Year
            }));
        }

        // Day count on the School Calendar -- exactly what Apply will count.
        [HttpGet]
        public async Task<IActionResult> CountDays(string? fromDate, string? toDate, bool halfDay = false)
        {
            if (string.IsNullOrWhiteSpace(fromDate) || string.IsNullOrWhiteSpace(toDate))
                return Json(new { success = false, days = 0 });
            var r = await _self.CountDaysAsync(fromDate, toDate, halfDay, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, days = r.Days, message = r.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Apply(string? leaveType, string? fromDate, string? toDate,
                                               string? reason, bool halfDay = false)
        {
            if (!await PayrollOnAsync()) return Json(new { success = false, message = ModuleOffMessage });
            if (string.IsNullOrWhiteSpace(fromDate) || string.IsNullOrWhiteSpace(toDate))
                return Json(new { success = false, message = "Choose both the from and to dates." });

            var r = await _self.ApplyAsync(leaveType, fromDate, toDate, reason, halfDay,
                                           TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message, days = r.Days });
        }

        // Withdraw one of my own requests (pending, or approved and not yet started). Reason required.
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Cancel(int id, string? reason)
        {
            // Cancelling stays possible with the module off, so a request is never stuck.
            var r = await _self.CancelAsync(id, reason, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, message = r.Message });
        }

        // ── Helpers ──────────────────────────────────────────────
        private const string ModuleOffMessage = "Leave and payroll are turned off for this school.";

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
