using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Attendance.Controllers
{
    /// <summary>
    /// Attendance › Overview (/attendance/overview): today's registers (who has not
    /// taken attendance), and for a date range the missing registers with the class
    /// teacher responsible, week by week, classes worst-first and a class-teacher
    /// leaderboard. Read-only (core.sp_attendance_overview). It compares teachers, so it
    /// needs reports.view (admin / principal), not the teachers' attendance keys.
    /// </summary>
    [Area("Attendance")]
    [RequiresModule(SchoolModule.Attendance)]
    [HasPermission("reports.view")]
    public class AttendanceOverviewController : Controller
    {
        private readonly IDashboardReportService _reports;

        public AttendanceOverviewController(IDashboardReportService reports)
        {
            _reports = reports;
        }

        [Route("attendance/overview")]
        public IActionResult Index() => View();

        [HttpGet]
        public async Task<IActionResult> Data(string? day, string? from, string? to)
        {
            var today = Dates.Today;
            var d = await _reports.GetAttendanceOverviewAsync(
                Dates.Norm(day) ?? today,
                Dates.Norm(from) ?? Dates.Parse(today)!.Value.AddDays(-29).ToString("yyyy-MM-dd"),
                Dates.Norm(to) ?? today,
                TenantId(), SchoolId(), UserId());
            return Json(new { today, data = d });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
