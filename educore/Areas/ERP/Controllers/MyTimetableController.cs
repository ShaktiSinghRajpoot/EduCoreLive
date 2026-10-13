using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// "My Timetable" (/ERP/MyTimetable) -- a teacher's own week, and requesting
    /// periods. A request stays Pending until an admin approves it on the
    /// Timetable page; only then does it go live.
    ///
    /// Same rule as My Leave: no permission key, having a staff record IS the
    /// permission, and the proc resolves the teacher from the logged-in user on
    /// every call. No action takes a staff id from the browser.
    /// </summary>
    [Area("ERP")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class MyTimetableController : Controller
    {
        private readonly ITimetableService _timetable;
        private readonly IStaffSelfService _self;

        public MyTimetableController(ITimetableService timetable, IStaffSelfService self)
        {
            _timetable = timetable;
            _self = self;
        }

        [HttpGet]
        public async Task<IActionResult> Index()
        {
            ViewBag.Me = await _self.GetMeAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        // Everything the page draws: days + periods, the sections to pick from,
        // the teacher's live periods and their requests.
        [HttpGet]
        public async Task<IActionResult> Data()
        {
            var me = await _self.GetMeAsync(TenantId(), SchoolId(), UserId());
            if (me == null) return Json(new { success = false, message = "Only staff can use My Timetable." });

            var setup    = await _timetable.GetSetupAsync(TenantId(), SchoolId(), UserId());
            var live     = await _timetable.GetTeacherGridAsync(me.StaffId, TenantId(), SchoolId(), UserId());
            var requests = await _timetable.GetMyRequestsAsync(TenantId(), SchoolId(), UserId());

            return Json(new
            {
                success  = true,
                days     = setup.Days.Select(d => new { day = d.DayOfWeek, label = d.DayLabel }),
                periods  = setup.Periods.Select(p => new { day = p.DayOfWeek, seq = p.PeriodSeq, label = p.Label, type = p.PeriodType,
                                                          time = p.StartTime + "–" + p.EndTime }),
                sections = setup.Sections.Select(s => new { id = s.SectionId, label = s.Label }),
                live     = live.Select(e => new { day = e.DayOfWeek, seq = e.PeriodSeq, subjectId = e.SubjectId, subject = e.SubjectName, section = e.SectionLabel }),
                requests = requests.Select(r => new
                {
                    id = r.RequestId, status = r.Status, note = r.Note, day = r.DayOfWeek, seq = r.PeriodSeq, period = r.PeriodLabel,
                    section = r.SectionLabel, subject = r.SubjectName, liveNow = r.LiveNow, at = r.RequestedAt
                })
            });
        }

        // The subjects of the picked section's class.
        [HttpGet]
        public async Task<IActionResult> Subjects(int sectionId)
        {
            var grid = await _timetable.GetGridAsync(sectionId, TenantId(), SchoolId(), UserId());
            return Json(grid.Subjects.Select(s => new { id = s.SubjectId, name = s.SubjectName }));
        }

        public class RequestDto
        {
            public int SectionId { get; set; }
            public int Day       { get; set; }
            public int PeriodSeq { get; set; }
            public int SubjectId { get; set; }
            public int RequestId { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SendRequest([FromBody] RequestDto dto)
        {
            var result = await _timetable.RequestPeriodAsync(
                dto?.SectionId ?? 0, dto?.Day ?? 0, dto?.PeriodSeq ?? 0, dto?.SubjectId ?? 0,
                TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Cancel([FromBody] RequestDto dto)
        {
            var result = await _timetable.CancelRequestAsync(dto?.RequestId ?? 0, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
