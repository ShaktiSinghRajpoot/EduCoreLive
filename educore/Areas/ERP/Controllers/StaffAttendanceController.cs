using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Staff Attendance (/ERP/StaffAttendance): mark the day, the month register,
    /// and substitute teachers for the periods of anyone absent or on leave.
    /// Seeing it needs staff.view; marking staff.manage; substitutions academics.manage.
    /// </summary>
    [Area("ERP")]
    [HasPermission("staff.view")]
    public class StaffAttendanceController : Controller
    {
        private readonly IStaffAttendanceService _att;

        public StaffAttendanceController(IStaffAttendanceService att)
        {
            _att = att;
        }

        public async Task<IActionResult> Index()
        {
            ViewBag.CanMark  = await HasPermissionAttribute.UserHasAsync(this, "staff.manage");
            ViewBag.CanCover = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
            return View();
        }

        // ── Mark a day ───────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Day(string? date, [FromServices] ModuleFlags modules)
        {
            var d = Dates.Norm(date) ?? Dates.Today;
            var sheet = await _att.GetDayAsync(d, TenantId(), SchoolId(), UserId());
            bool leaveOn = await modules.PayrollOn();   // approved leave belongs to the Payroll module
            return Json(new
            {
                date = d,
                calendar = sheet.CalendarNote,
                staff = sheet.Staff.Select(s => new
                {
                    id     = s.StaffId,
                    name   = s.FullName,
                    code   = s.EmployeeCode,
                    desg   = s.Designation,
                    type   = s.StaffType,
                    status = s.Status,
                    remark = s.Remark,
                    marked = s.MarkedAt?.ToString("dd MMM, hh:mm tt"),
                    leave  = leaveOn ? s.LeaveType : null
                })
            });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] SaveDayRequest req)
        {
            if (req?.Marks == null || req.Marks.Count == 0 || string.IsNullOrWhiteSpace(req.Date))
                return Json(new { success = false, message = "Nothing to save." });

            var marks = req.Marks.Select(m => new StaffDayRow { StaffId = m.Id, Status = m.Status, Remark = m.Remark?.Trim() }).ToList();
            var (ok, msg) = await _att.SaveDayAsync(Dates.Norm(req.Date)!, marks, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class SaveDayRequest
        {
            public string?          Date  { get; set; }
            public List<MarkItem>?  Marks { get; set; }
        }

        public class MarkItem
        {
            public int     Id     { get; set; }
            public string? Status { get; set; }
            public string? Remark { get; set; }
        }

        // ── Month register ───────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Month(string? month)
        {
            if (string.IsNullOrWhiteSpace(month)) month = Dates.Today.Substring(0, 7);
            var reg = await _att.GetMonthAsync(month, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                month,
                staff = reg.Staff.Select(s => new { id = s.StaffId, name = s.FullName, desg = s.Designation }),
                marks = reg.Marks.Select(m => new { id = m.StaffId, day = m.Day, s = m.Status })
            });
        }

        // ── Substitutions ────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Substitutions(string? date)
        {
            var d = Dates.Norm(date) ?? Dates.Today;
            var (needs, teachers) = await _att.GetSubstitutionDayAsync(d, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                date = d,
                needs = needs.Select(n => new
                {
                    sectionId = n.SectionId,
                    seq       = n.PeriodSeq,
                    period    = n.PeriodLabel,
                    section   = n.SectionLabel,
                    subject   = n.SubjectName,
                    teacher   = n.TeacherName,
                    reason    = n.AwayReason,
                    subId     = n.SubstituteId,
                    subName   = n.SubstituteName
                }),
                teachers = teachers.Select(t => new { id = t.StaffId, name = t.FullName, away = t.AwayReason, busy = t.Busy })
            });
        }

        [HttpPost]
        [HasPermission("academics.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Assign([FromBody] SubstituteRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.Date) || req.SectionId <= 0 || req.Seq <= 0)
                return Json(new { success = false, message = "Invalid request." });

            var (ok, msg) = req.SubstituteId > 0
                ? await _att.AssignSubstituteAsync(Dates.Norm(req.Date)!, req.SectionId, req.Seq, req.SubstituteId, TenantId(), SchoolId(), UserId())
                : await _att.RemoveSubstituteAsync(Dates.Norm(req.Date)!, req.SectionId, req.Seq, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class SubstituteRequest
        {
            public string? Date         { get; set; }
            public int     SectionId    { get; set; }
            public int     Seq          { get; set; }
            /// <summary>0 removes the substitute.</summary>
            public int     SubstituteId { get; set; }
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
