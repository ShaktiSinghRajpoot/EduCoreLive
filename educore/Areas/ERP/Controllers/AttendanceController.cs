using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("attendance.view")]
    public class AttendanceController : Controller
    {
        private readonly IAttendanceService _attendance;
        private readonly IBaseService _baseService;
        private readonly IClassTeacherService _classTeacher;
        private readonly EduCoreDataAccessLayer.Services.IPermissionService _permission;
        private readonly ISchoolCalendarService _calendar;

        public AttendanceController(
            IAttendanceService attendance,
            IBaseService baseService,
            IClassTeacherService classTeacher,
            EduCoreDataAccessLayer.Services.IPermissionService permission,
            ISchoolCalendarService calendar)
        {
            _attendance = attendance;
            _baseService = baseService;
            _classTeacher = classTeacher;
            _permission = permission;
            _calendar = calendar;
        }

        // Admins/principals may mark any section; a class teacher only their own.
        private async Task<bool> CanMarkAsync(string? className, string? section)
        {
            var (isAdmin, _) = await _permission.GetUserAccessAsync(TenantId(), SchoolId(), UserId());
            if (isAdmin) return true;
            return !string.IsNullOrWhiteSpace(className)
                && await _classTeacher.IsClassTeacherAsync(className, section, TenantId(), SchoolId(), UserId());
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // The daily marking screen. The class list feeds the selector; sections and
        // the roster load over AJAX as the teacher picks class / section / date.
        [HttpGet]
        public async Task<IActionResult> StudentAttendance()
        {
            try { ViewBag.ClassList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<SelectListItem>(); }
            ViewBag.Today = Dates.Today;   // the school's clock, not the browser's UTC date
            return View();
        }

        // Sections for a class — fills the Section dropdown when the class changes.
        [HttpGet]
        public async Task<IActionResult> Sections(string @class)
        {
            var sections = await _attendance.GetSectionsAsync(@class, TenantId(), SchoolId(), UserId());
            return Json(sections);
        }

        // The roster for a class/section/date, with any marks already made.
        [HttpGet]
        public async Task<IActionResult> Roster(string @class, string? section, string? date)
        {
            var d = Dates.Norm(date) ?? Dates.Today;
            var roster = await _attendance.GetRosterAsync(@class, section, d, TenantId(), SchoolId(), UserId());

            // Why Save is off, shown next to the button instead of a silent disabled state.
            string? cannotMark = null;
            if (!await HasPermissionAttribute.UserHasAsync(this, "attendance.manage"))
                cannotMark = "Your role can view attendance but not mark it.";
            else if (!await CanMarkAsync(@class, section))
                cannotMark = "You can mark attendance only for classes where you are the class teacher.";

            // Holiday / weekly off from the School Calendar -- sp_attendance_save refuses these days.
            var day = await _calendar.GetDayStatusAsync(
                DateTime.ParseExact(d, Dates.Iso, System.Globalization.CultureInfo.InvariantCulture),
                TenantId(), SchoolId(), UserId());

            return Json(new
            {
                canMark = cannotMark == null,
                cannotMark,
                dayType  = day.DayType,     // working | weekly_off | holiday | half_day
                dayTitle = day.Title,
                students = roster.Select(s => new
                {
                    id     = s.StudentId,
                    name   = s.StudentName,
                    roll   = s.RollNo,
                    parent = s.GuardianName,
                    phone  = s.Mobile,
                    // "" = not marked yet; otherwise present | absent | late | leave as stored.
                    status = string.IsNullOrWhiteSpace(s.Status) ? "" : s.Status.ToLowerInvariant(),
                    marked = s.IsMarked
                })
            });
        }

        [HttpPost]
        [HasPermission("attendance.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] AttendanceSaveRequest request)
        {
            var d = Dates.Norm(request?.Date);
            if (d == null)
                return Json(new { success = false, message = "Choose a valid date." });

            // Only the class teacher of this section (or an admin) may save it.
            if (!await CanMarkAsync(request!.Class, request.Section))
                return Json(new { success = false, message = "You can mark attendance only for your assigned class-section." });

            // The class-section goes to the proc too, so it can refuse any student
            // who is not on that register (the gate above only approved the section).
            var result = await _attendance.SaveAsync(d, request.Class!, request.Section, request.Items,
                TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, saved = result.Saved });
        }

        // The monthly report screen. Class list feeds the selector; sections and
        // the register load over AJAX as the filters change.
        [HttpGet]
        public async Task<IActionResult> AttendanceReport()
        {
            try { ViewBag.ClassList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<SelectListItem>(); }
            return View();
        }

        // A class/section's whole month of attendance — feeds all three report views.
        [HttpGet]
        public async Task<IActionResult> MonthRegister(string @class, string? section, int month, int year)
        {
            var reg = await _attendance.GetMonthRegisterAsync(@class, section, month, year, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                schoolDays = reg.SchoolDays,
                students   = reg.Students.Select(s => new { id = s.Id, name = s.Name, roll = s.Roll, days = s.SchoolDays }),
                marks      = reg.Marks.Select(m => new { studentId = m.StudentId, day = m.Day, mark = m.Mark }),
                daysOff    = reg.DaysOff.Select(o => new { day = o.Day, type = o.DayType, title = o.Title })
            });
        }
    }
}
