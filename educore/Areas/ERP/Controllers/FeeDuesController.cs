using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Month-wise Dues (/ERP/FeeDues): what is still unpaid month by month, class by
    /// class and child by child, with a warning on children who look like they have
    /// left the school (no attendance for three weeks while their class's register
    /// was kept). fee_month_dues.sql.
    /// </summary>
    [Area("ERP")]
    [HasPermission("fees.view")]
    public class FeeDuesController : Controller
    {
        private readonly IFeeMonthDuesService _dues;

        public FeeDuesController(IFeeMonthDuesService dues)
        {
            _dues = dues;
        }

        public async Task<IActionResult> Index([FromServices] IBaseService baseService)
        {
            try { ViewBag.ClassList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
            try { ViewBag.YearList = await baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.YearList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }
            ViewBag.CanCollect = await HasPermissionAttribute.UserHasAsync(this, "fees.collect");
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Data(string? year, string? from, string? upto, string? cls, string? sec)
        {
            if (string.IsNullOrWhiteSpace(year)) return Json(new { success = false, message = "Choose the session." });
            if (!string.IsNullOrWhiteSpace(from) && !string.IsNullOrWhiteSpace(upto) && string.CompareOrdinal(from, upto) > 0)
                return Json(new { success = false, message = "The \"from\" month is after the \"to\" month." });
            var d = await _dues.GetAsync(year, from, upto, cls, sec, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success  = true,
                months   = d.Months.Select(m => new { month = m.Month, due = m.Due, collected = m.Collected, pending = m.Pending, children = m.Children }),
                classes  = d.Classes.Select(c => new { cls = c.ClassName, sec = c.Section, children = c.Children, withDues = c.WithDues, pending = c.Pending }),
                students = d.Students.Select(s => new
                {
                    id = s.StudentId, publicId = s.PublicId, name = s.StudentName, admNo = s.AdmissionNo,
                    father = s.GuardianName, mobile = s.Mobile, cls = s.ClassName, sec = s.Section, roll = s.RollNo,
                    status = s.Status, pending = s.Pending, monthsCount = s.MonthsCount, months = s.Months,
                    oldest = s.OldestMonth, lastPaid = s.LastPayment, lastPresent = s.LastPresent,
                    classDays = s.ClassDays, presentDays = s.PresentDays, mayHaveLeft = s.MayHaveLeft
                })
            });
        }

        // One child's attendance for the "may have left" warning.
        [HttpGet]
        public async Task<IActionResult> Attendance(int id, string? year)
        {
            var a = await _dues.GetAttendanceAsync(id, year ?? "", TenantId(), SchoolId(), UserId());
            if (a == null) return Json(new { success = false, message = "Student not found." });
            return Json(new
            {
                success = true, name = a.StudentName, lastPresent = a.LastPresent, lastMarked = a.LastMarked,
                streak = a.AbsentStreak, marked = a.Marked, present = a.Present,
                months = a.Months.Select(m => new { month = m.Month, present = m.Present, absent = m.Absent, leave = m.OnLeave })
            });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
