using educore.Helpers;
using educore.Services;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Attendance.Controllers
{
    [Area("Attendance")]
    [RequiresModule(SchoolModule.Attendance)]
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

        // Admins/principals may mark any section; a class teacher only their own --
        // or, on a day the class teacher is away, a teacher who takes a period in
        // that section that day (QA BUG-114, see class_teacher_acting.sql).
        private async Task<bool> CanMarkAsync(string? className, string? section, string date)
        {
            var (isAdmin, _) = await _permission.GetUserAccessAsync(TenantId(), SchoolId(), UserId());
            if (isAdmin) return true;
            if (string.IsNullOrWhiteSpace(className)) return false;
            if (await _classTeacher.IsClassTeacherAsync(className, section, TenantId(), SchoolId(), UserId()))
                return true;
            var (acting, _) = await _classTeacher.IsActingClassTeacherAsync(className, section, date, TenantId(), SchoolId(), UserId());
            return acting;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // The daily marking screen. The class list feeds the selector; sections and
        // the roster load over AJAX as the teacher picks class / section / date.
        [HttpGet("attendance/mark")]
        public async Task<IActionResult> StudentAttendance([FromServices] SchoolMessenger messenger)
        {
            // WhatsApp alerts straight from the server when the Super Admin switched them on
            ViewBag.WhatsAppOn = await messenger.IsOnAsync(TenantId(), SchoolId());
            ViewBag.WhatsAppTest = messenger.TestMode;
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
            else if (!await CanMarkAsync(@class, section, d))
                cannotMark = "You can mark attendance only for classes where you are the class teacher (or, when the class teacher is away, a class you teach that day).";

            // Standing in for an absent class teacher: say so on the page.
            string? actingFor = null;
            if (cannotMark == null)
            {
                var (acting, teacher) = await _classTeacher.IsActingClassTeacherAsync(@class, section, d, TenantId(), SchoolId(), UserId());
                if (acting) actingFor = teacher;
            }

            // Holiday / weekly off from the School Calendar -- sp_attendance_save refuses these days.
            var day = await _calendar.GetDayStatusAsync(
                DateTime.ParseExact(d, Dates.Iso, System.Globalization.CultureInfo.InvariantCulture),
                TenantId(), SchoolId(), UserId());

            return Json(new
            {
                canMark = cannotMark == null,
                cannotMark,
                actingFor,
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

        // Absent alert on WhatsApp to the parents of every child marked absent in this class
        // on this date. Who is absent and their numbers come from the saved register, never
        // from the browser, so the button cannot be used to message anyone else.
        [HttpPost]
        [HasPermission("attendance.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SendAbsentAlerts([FromBody] AttendanceSaveRequest request,
                                                          [FromServices] SchoolMessenger messenger,
                                                          [FromServices] ISchoolSettingsService settings)
        {
            var d = Dates.Norm(request?.Date);
            if (d == null || string.IsNullOrWhiteSpace(request!.Class))
                return Json(new { success = false, message = "Choose the class and date." });
            if (!await messenger.IsOnAsync(TenantId(), SchoolId()))
                return Json(new { success = false, message = "WhatsApp is not switched on for this school." });
            if (!await CanMarkAsync(request.Class, request.Section, d))
                return Json(new { success = false, message = "You can send alerts only for a class whose attendance you can mark." });

            var roster = await _attendance.GetRosterAsync(request.Class, request.Section, d, TenantId(), SchoolId(), UserId());
            var absent = roster.Where(s => s.IsMarked && string.Equals(s.Status, "absent", StringComparison.OrdinalIgnoreCase)).ToList();
            if (absent.Count == 0)
                return Json(new { success = false, message = "No child is marked absent (save the attendance first)." });

            string schoolName = "";
            try { schoolName = (await settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId()))?.SchoolName ?? ""; }
            catch { /* the template still goes, without the school's name */ }
            string cls = request.Class + (string.IsNullOrWhiteSpace(request.Section) ? "" : "-" + request.Section);
            string day = Dates.Show(d, "dd MMM yyyy");

            var counts = new Dictionary<string, int>();
            foreach (var s in absent)
            {
                var status = await messenger.SendAsync(TenantId(), SchoolId(), UserId(), SchoolMessenger.Absent,
                    s.StudentId, s.GuardianName ?? s.StudentName, s.Mobile, new[] { s.StudentName, cls, day, schoolName });
                counts[status] = counts.GetValueOrDefault(status) + 1;
            }

            string Part(string k, string label) => counts.GetValueOrDefault(k) > 0 ? $"{counts[k]} {label}" : "";
            var msg = string.Join(", ", new[] { Part("Sent", "sent"), Part("Test", "recorded in test mode (WhatsApp account not connected yet)"),
                                               Part("Failed", "failed"), Part("NoPhone", "with no mobile number") }.Where(x => x != ""));
            return Json(new { success = counts.GetValueOrDefault("Sent") + counts.GetValueOrDefault("Test") > 0, message = "Absent alerts: " + msg + ".",
                              sent = counts.GetValueOrDefault("Sent"), test = counts.GetValueOrDefault("Test"),
                              failed = counts.GetValueOrDefault("Failed"), noPhone = counts.GetValueOrDefault("NoPhone") });
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
            if (!await CanMarkAsync(request!.Class, request.Section, d))
                return Json(new { success = false, message = "You can mark attendance only for your assigned class-section." });

            // The class-section goes to the proc too, so it can refuse any student
            // who is not on that register (the gate above only approved the section).
            var result = await _attendance.SaveAsync(d, request.Class!, request.Section, request.Items,
                TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, saved = result.Saved });
        }

        // The monthly report screen. Class list feeds the selector; sections and
        // the register load over AJAX as the filters change.
        [HttpGet("attendance/register")]
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
