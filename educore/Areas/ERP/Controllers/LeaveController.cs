using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("staff.view")]
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

        public async Task<IActionResult> LeaveManagement()
        {
            // The staff picker used to be five hardcoded names.
            var staff = await _staffService.GetStaffAsync(TenantId(), SchoolId(), UserId(),
                                                          statusFilter: "Active");
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
                from         = r.FromDate?.ToString("dd MMM yyyy") ?? "",
                to           = r.ToDate?.ToString("dd MMM yyyy") ?? "",
                days         = r.Days,
                reason       = r.Reason ?? "",
                status       = r.Status,
                remark       = r.DecisionRemark ?? "",
                applied      = r.AppliedAt?.ToString("dd MMM yyyy") ?? "",
                onLeaveToday = r.OnLeaveToday,
                unpaid       = r.IsUnpaid
            }));
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ApplyLeave(int staffId, string leaveType,
                                                    DateOnly? fromDate, DateOnly? toDate, string? reason)
        {
            if (fromDate == null || toDate == null)
                return Json(new { success = false, message = "Choose both the from and to dates." });

            var result = await _leaveService.ApplyAsync(
                staffId, leaveType, fromDate.Value, toDate.Value, reason,
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
    }
}
