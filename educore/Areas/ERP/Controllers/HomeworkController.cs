using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Homework (/ERP/Homework). Teachers give homework to a class section and
    /// tick who did it; anyone with academics.view sees all of it, academics.manage
    /// may change anyone's. A teacher needs no permission key: having a staff
    /// record is enough (like My Timetable), and the procedure only lets them
    /// change their own homework.
    /// </summary>
    [Area("ERP")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class HomeworkController : Controller
    {
        private readonly IHomeworkService _homework;
        private readonly ITimetableService _timetable;
        private readonly IStaffSelfService _self;

        public HomeworkController(IHomeworkService homework, ITimetableService timetable, IStaffSelfService self)
        {
            _homework = homework;
            _timetable = timetable;
            _self = self;
        }

        public async Task<IActionResult> Index()
        {
            if (!await AllowedAsync()) return Forbid();

            ViewBag.IsStaff = await _self.HasStaffRecordAsync(TenantId(), SchoolId(), UserId());
            ViewBag.CanManage = await CanManageAsync();
            return View();
        }

        // ── GET: /ERP/Homework/Sections ── class sections of the current session
        [HttpGet]
        public async Task<IActionResult> Sections()
        {
            if (!await AllowedAsync()) return Forbid();
            var setup = await _timetable.GetSetupAsync(TenantId(), SchoolId(), UserId());
            return Json(setup.Sections.Select(s => new { id = s.SectionId, label = s.Label }));
        }

        // ── GET: /ERP/Homework/Subjects?sectionId= ── the subjects of that section's class
        [HttpGet]
        public async Task<IActionResult> Subjects(int sectionId)
        {
            if (!await AllowedAsync()) return Forbid();
            var grid = await _timetable.GetGridAsync(sectionId, TenantId(), SchoolId(), UserId());
            return Json(grid.Subjects.Select(s => new { id = s.SubjectId, name = s.SubjectName }));
        }

        [HttpGet]
        public async Task<IActionResult> List(int? sectionId, string? from, string? to, bool mine = false)
        {
            if (!await AllowedAsync()) return Forbid();
            var rows = await _homework.GetListAsync(sectionId > 0 ? sectionId : null, Dates.Norm(from), Dates.Norm(to), mine,
                                                    await CanManageAsync(), TenantId(), SchoolId(), UserId());
            return Json(rows.Select(h => new
            {
                id = h.Id, sectionId = h.SectionId, section = h.SectionLabel, subjectId = h.SubjectId, subject = h.SubjectName,
                teacher = h.TeacherName, title = h.Title, details = h.Details, given = h.AssignedOn, due = h.DueOn,
                canEdit = h.CanEdit, done = h.DoneCount, notDone = h.NotDoneCount, students = h.StudentCount
            }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] HomeworkRequest req)
        {
            if (req == null) return Json(new { success = false, message = "Invalid request." });
            var h = new Homework
            {
                Id = req.Id ?? 0, SectionId = req.SectionId, SubjectId = req.SubjectId,
                Title = (req.Title ?? "").Trim(), Details = req.Details?.Trim(),
                AssignedOn = Dates.Norm(req.Given) ?? Dates.Today, DueOn = Dates.Norm(req.Due) ?? ""
            };
            var (ok, msg) = await _homework.SaveAsync(h, await CanManageAsync(), TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Delete(int id)
        {
            var (ok, msg) = await _homework.DeleteAsync(id, await CanManageAsync(), TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpGet]
        public async Task<IActionResult> Students(int id)
        {
            if (!await AllowedAsync()) return Forbid();
            var rows = await _homework.GetStudentsAsync(id, await CanManageAsync(), TenantId(), SchoolId(), UserId());
            return Json(rows.Select(s => new { id = s.StudentId, name = s.StudentName, roll = s.RollNo, adm = s.AdmissionNo, status = s.Status }));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Check([FromBody] CheckRequest req)
        {
            if (req?.Marks == null || req.Marks.Count == 0) return Json(new { success = false, message = "Nothing to save." });
            var marks = req.Marks.Select(m => new HomeworkStudent { StudentId = m.Id, Status = m.Status }).ToList();
            var (ok, msg) = await _homework.CheckAsync(req.Id, marks, await CanManageAsync(), TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class HomeworkRequest
        {
            public int?    Id        { get; set; }
            public int     SectionId { get; set; }
            public int     SubjectId { get; set; }
            public string? Title     { get; set; }
            public string? Details   { get; set; }
            public string? Given     { get; set; }
            public string? Due       { get; set; }
        }

        public class CheckRequest
        {
            public int               Id    { get; set; }
            public List<CheckItem>?  Marks { get; set; }
        }

        public class CheckItem
        {
            public int     Id     { get; set; }
            public string? Status { get; set; }
        }

        // Staff (teachers) and anyone who can see academics.
        private async Task<bool> AllowedAsync() =>
            await _self.HasStaffRecordAsync(TenantId(), SchoolId(), UserId())
            || await HasPermissionAttribute.UserHasAsync(this, "academics.view");

        private Task<bool> CanManageAsync() => HasPermissionAttribute.UserHasAsync(this, "academics.manage");

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
