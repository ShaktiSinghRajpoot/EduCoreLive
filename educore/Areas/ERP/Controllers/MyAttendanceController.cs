using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// "My Attendance" (/ERP/MyAttendance) -- a member of staff's own attendance over
    /// any date range: totals, attendance % and day by day.
    ///
    /// No permission key on purpose (same as My Leave / My Payslip): the staff id is
    /// never taken from the browser, only from the signed-in user's own staff record,
    /// so nobody can open someone else's attendance here.
    /// </summary>
    [Area("ERP")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class MyAttendanceController : Controller
    {
        private readonly IStaffSelfService _self;
        private readonly IStaffAttendanceService _att;

        public MyAttendanceController(IStaffSelfService self, IStaffAttendanceService att)
        {
            _self = self;
            _att = att;
        }

        [HttpGet]
        public async Task<IActionResult> Index()
        {
            ViewBag.Me = await _self.GetMeAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Data(string? from, string? to, [FromServices] ModuleFlags modules)
        {
            var me = await _self.GetMeAsync(TenantId(), SchoolId(), UserId());
            if (me == null) return Json(new { success = false, message = "No staff record is linked to your login." });

            try
            {
                var h = await _att.GetHistoryAsync(me.StaffId, from, to, TenantId(), SchoolId(), UserId());
                bool leaveOn = await modules.PayrollOn();   // approved leave belongs to the Payroll module
                // h.Staff (everyone's names) is not sent: this page is about one person.
                return Json(new
                {
                    success = true,
                    from = h.From, to = h.To,
                    summary = new { working = h.WorkingDays, present = h.Present, late = h.Late, absent = h.Absent,
                                    halfDay = h.HalfDay, onLeave = h.OnLeave, notMarked = h.NotMarked, percent = h.Percent },
                    days = h.Days.Select(d => new { day = d.Day, wd = d.Weekday, type = d.DayType, employed = d.Employed,
                                                    s = d.Status, remark = d.Remark, leave = leaveOn ? d.LeaveType : null })
                });
            }
            catch (Npgsql.PostgresException ex)
            {
                return Json(new { success = false, message = ex.MessageText });
            }
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
