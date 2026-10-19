using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Staff.Controllers
{
    [Area("Staff")]
    [HasPermission("staff.view")]
    [RequiresModule(SchoolModule.Payroll)]
    public class LeaveController : Controller
    {
        private readonly IStaffLeaveService _leaveService;
        private readonly IStaffService _staffService;

        public LeaveController(IStaffLeaveService leaveService, IStaffService staffService)
        {
            _leaveService = leaveService;
            _staffService = staffService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        [Route("staff/leave")]
        public async Task<IActionResult> LeaveManagement()
        {
            // Everyone still employed: Active AND "On Leave" (long leave such as
            // maternity still needs leave records). Only Inactive staff are left out
            // -- the proc refuses them anyway.
            var staff = (await _staffService.GetStaffAsync(TenantId(), SchoolId(), UserId()))
                        .Where(s => s.Status != "Inactive").ToList();
            ViewBag.StaffList = staff;
            return View();
        }

        // The page filters, counts and searches client-side, so it loads the whole
        // list once. A school's leave register is small enough for that.
        [HttpGet]
        public async Task<IActionResult> List(string? status = null)
        {
            var rows = await _leaveService.GetLeavesAsync(TenantId(), SchoolId(), UserId(), status: status);

            return Json(rows.Select(r => new
            {
                id           = r.LeaveId,
                staffId      = r.StaffId,
                name         = r.FullName,
                code         = r.EmployeeCode ?? "",
                designation  = r.Designation ?? "",
                type         = r.LeaveType,
                from         = string.IsNullOrWhiteSpace(r.FromDate) ? "" : Dates.Show(r.FromDate, "dd MMM yyyy"),
                to           = string.IsNullOrWhiteSpace(r.ToDate) ? "" : Dates.Show(r.ToDate, "dd MMM yyyy"),
                // ISO dates for the page's own date logic (can this still be cancelled?).
                fromIso      = r.FromDate ?? "",
                days         = r.Days,
                halfDay      = r.HalfDay,
                reason       = r.Reason ?? "",
                status       = r.Status,
                remark       = r.DecisionRemark ?? "",
                cancelReason = r.CancelReason ?? "",
                applied      = r.AppliedAt?.ToString("dd MMM yyyy") ?? "",
                onLeaveToday = r.OnLeaveToday,
                unpaid       = r.IsUnpaid
            }));
        }

        // Day count preview on the School Calendar -- exactly what Apply will count.
        [HttpGet]
        public async Task<IActionResult> CountDays(string? fromDate, string? toDate, bool halfDay = false)
        {
            if (string.IsNullOrWhiteSpace(fromDate) || string.IsNullOrWhiteSpace(toDate))
                return Json(new { success = false, days = 0 });
            var r = await _leaveService.CountDaysAsync(fromDate, toDate, halfDay, TenantId(), SchoolId(), UserId());
            return Json(new { success = r.Success, days = r.Days, message = r.Message });
        }

        // Yearly balance per leave type for the chosen staff member.
        [HttpGet]
        public async Task<IActionResult> Balance(int staffId, string? date = null)
        {
            var rows = await _leaveService.GetBalanceAsync(staffId, date, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(b => new
            {
                type = b.LeaveType, entitled = b.Entitled, taken = b.Taken,
                pending = b.Pending, remaining = b.Remaining, year = b.Year
            }));
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ApplyLeave(int staffId, string leaveType,
                                                    string? fromDate, string? toDate, string? reason,
                                                    bool halfDay = false)
        {
            if (fromDate == null || toDate == null)
                return Json(new { success = false, message = "Choose both the from and to dates." });

            var result = await _leaveService.ApplyAsync(
                staffId, leaveType, fromDate, toDate, reason, halfDay,
                TenantId(), SchoolId(), UserId());

            return Json(new { success = result.Success, message = result.Message, days = result.Days });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Approve(int id, string? remark)
        {
            var result = await _leaveService.DecideAsync(id, "Approved", remark,
                                                         TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Reject(int id, string? remark)
        {
            var result = await _leaveService.DecideAsync(id, "Rejected", remark,
                                                         TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // Withdraw a request (pending, or approved and not yet started). Reason required.
        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Cancel(int id, string? reason)
        {
            var result = await _leaveService.CancelAsync(id, reason, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }
    }
}
