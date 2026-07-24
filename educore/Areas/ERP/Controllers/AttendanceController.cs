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

        public AttendanceController(
            IAttendanceService attendance,
            IBaseService baseService,
            IClassTeacherService classTeacher,
            EduCoreDataAccessLayer.Services.IPermissionService permission)
        {
            _attendance = attendance;
            _baseService = baseService;
            _classTeacher = classTeacher;
            _permission = permission;
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
            if (!DateOnly.TryParse(date, out var d)) d = DateOnly.FromDateTime(DateTime.Today);
            var roster = await _attendance.GetRosterAsync(@class, section, d, TenantId(), SchoolId(), UserId());
            var canMark = await CanMarkAsync(@class, section);

            return Json(new
            {
                canMark,
                students = roster.Select(s => new
                {
                    id     = s.StudentId,
                    name   = s.StudentName,
                    roll   = s.RollNo,
                    parent = s.GuardianName,
                    phone  = s.Mobile,
                    status = string.IsNullOrWhiteSpace(s.Status) ? "present" : s.Status.ToLowerInvariant()
                })
            });
        }

        [HttpPost]
        [HasPermission("attendance.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] AttendanceSaveRequest request)
        {
            if (!DateOnly.TryParse(request?.Date, out var d))
                return Json(new { success = false, message = "Choose a valid date." });

            // Only the class teacher of this section (or an admin) may save it.
            if (!await CanMarkAsync(request!.Class, request.Section))
                return Json(new { success = false, message = "You can mark attendance only for your assigned class-section." });

            var result = await _attendance.SaveAsync(d, request.Items, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, saved = result.Saved });
        }

        [HttpGet]
        public IActionResult AttendanceReport()
        {
            return View();
        }
    }
}
