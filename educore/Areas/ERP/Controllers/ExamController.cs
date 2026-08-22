using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("exams.view")]
    public class ExamController : Controller
    {
        private readonly IExamService _exam;
        private readonly ISubjectService _subject;
        private readonly IReferenceDataService _referenceData;
        private readonly EduCoreDataAccessLayer.Services.IPermissionService _permission;

        public ExamController(
            IExamService exam,
            ISubjectService subject,
            IReferenceDataService referenceData,
            EduCoreDataAccessLayer.Services.IPermissionService permission)
        {
            _exam = exam;
            _subject = subject;
            _referenceData = referenceData;
            _permission = permission;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        private async Task<bool> IsAdminAsync()
        {
            var (isAdmin, _) = await _permission.GetUserAccessAsync(TenantId(), SchoolId(), UserId());
            return isAdmin;
        }

        // ── Exam Schedule ──
        // An exam is school-wide; each class it covers gets its own datesheet.

        [HttpGet]
        public async Task<IActionResult> CreateExam()
        {
            ViewBag.Classes = await _subject.GetClassesAsync(TenantId(), SchoolId(), UserId());

            try { ViewBag.ExamTypes = await _referenceData.GetOptionsAsync("ExamType", TenantId(), SchoolId()); }
            catch { ViewBag.ExamTypes = new List<SelectListItem>(); }

            var list = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId());
            ViewBag.AcademicYearName = list.AcademicYearName;

            return View();
        }

        // Subjects the class studies — the datesheet rows. Reads Subject Management.
        [HttpGet]
        public async Task<IActionResult> Subjects(int classId)
        {
            var subjects = await _subject.GetClassSubjectsAsync(classId, TenantId(), SchoolId(), UserId());
            return Json(subjects.Select(s => new { id = s.SubjectId, name = s.SubjectName }));
        }

        // This year's exams — also refreshes the list after a save or delete.
        [HttpGet]
        public async Task<IActionResult> Exams()
        {
            var data = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId());
            return Json(new
            {
                academicYear = data.AcademicYearName,
                exams = data.Exams.Select(e => new
                {
                    id           = e.ExamId,
                    name         = e.ExamName,
                    type         = e.ExamType,
                    typeLabel    = e.TypeLabel,
                    startDate    = e.StartDate,
                    endDate      = e.EndDate,
                    classCount   = e.ClassCount,
                    subjectCount = e.SubjectCount,
                    classNames   = e.ClassNames
                })
            });
        }

        // One exam with every class's datesheet — loads the form for edit.
        [HttpGet]
        public async Task<IActionResult> Exam(int id)
        {
            var exam = await _exam.GetExamAsync(id, TenantId(), SchoolId(), UserId());
            if (exam == null) return Json(new { success = false, message = "That exam was not found." });

            return Json(new
            {
                success = true,
                exam = new
                {
                    id        = exam.ExamId,
                    name      = exam.ExamName,
                    type      = exam.ExamType,
                    startDate = exam.StartDate,
                    endDate   = exam.EndDate,
                    classes   = exam.Classes.Select(c => new
                    {
                        classId   = c.AcademicClassId,
                        className = c.ClassName,
                        subjects  = c.Subjects.Select(s => new
                        {
                            id        = s.SubjectId,
                            name      = s.SubjectName,
                            date      = s.ExamDate,
                            maxMarks  = s.MaxMarks,
                            passMarks = s.PassMarks
                        })
                    })
                }
            });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveExam([FromBody] ExamSaveRequest request)
        {
            var result = await _exam.SaveExamAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, examId = result.ExamId });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteExam(int id)
        {
            var result = await _exam.DeleteExamAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }

        // ── Datesheet ──
        // "What is 1st class sitting, and on which date" — the printable view.

        [HttpGet]
        public async Task<IActionResult> Datesheet()
        {
            ViewBag.Classes = await _subject.GetClassesAsync(TenantId(), SchoolId(), UserId());

            var list = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId());
            ViewBag.Exams            = list.Exams;
            ViewBag.AcademicYearName = list.AcademicYearName;

            return View();
        }

        [HttpGet]
        public async Task<IActionResult> DatesheetRows(int classId, int examId)
        {
            var data = await _exam.GetDatesheetAsync(classId, examId, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                academicYear = data.AcademicYearName,
                rows = data.Rows.Select(r => new
                {
                    date      = r.ExamDate,
                    classId   = r.AcademicClassId,
                    className = r.ClassName,
                    subject   = r.SubjectName,
                    maxMarks  = r.MaxMarks,
                    passMarks = r.PassMarks,
                    examId    = r.ExamId,
                    examName  = r.ExamName,
                    typeLabel = r.TypeLabel
                })
            });
        }

        // ── Marks Entry ──
        // A SHEET is one (exam, class, section, subject): Exam -> Class -> Section -> Subject.

        [HttpGet]
        public async Task<IActionResult> MarkEntry(int examId = 0)
        {
            var list = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId());
            ViewBag.Exams            = list.Exams;
            ViewBag.AcademicYearName = list.AcademicYearName;
            ViewBag.SelectedExamId   = examId;

            // Only a school admin may reopen a finalized sheet.
            ViewBag.IsAdmin   = await IsAdminAsync();
            ViewBag.CanManage = await _permission.HasPermissionAsync(
                TenantId(), SchoolId(), UserId(), "exams.manage");

            return View();
        }

        // The classes this exam covers — the Class dropdown.
        [HttpGet]
        public async Task<IActionResult> ExamClasses(int examId)
        {
            var classes = await _exam.GetExamClassesAsync(examId, TenantId(), SchoolId(), UserId());
            return Json(classes.Select(c => new
            {
                id       = c.AcademicClassId,
                name     = c.ClassName,
                subjects = c.SubjectCount
            }));
        }

        // That class's datesheet + the sections that actually have students.
        [HttpGet]
        public async Task<IActionResult> ClassSetup(int examId, int classId)
        {
            var setup = await _exam.GetClassSetupAsync(examId, classId, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                subjects = setup.Subjects.Select(s => new
                {
                    id        = s.SubjectId,
                    name      = s.SubjectName,
                    date      = s.ExamDate,
                    maxMarks  = s.MaxMarks,
                    passMarks = s.PassMarks
                }),
                sections = setup.Sections.Select(s => new { name = s.Section, students = s.StudentCount })
            });
        }

        // One sheet: roster, marks so far, scale and lock state.
        [HttpGet]
        public async Task<IActionResult> Sheet(int examId, int classId, int subjectId, string? section)
        {
            var sheet = await _exam.GetSheetAsync(
                examId, classId, subjectId, section, TenantId(), SchoolId(), UserId());
            if (sheet == null) return Json(new { success = false, message = "That sheet was not found." });

            return Json(new
            {
                success     = true,
                maxMarks    = sheet.MaxMarks,
                passMarks   = sheet.PassMarks,
                examDate    = sheet.ExamDate,
                subjectName = sheet.SubjectName,
                isFinalized = sheet.IsFinalized,
                finalizedAt = sheet.FinalizedAt,
                students    = sheet.Students.Select(s => new
                {
                    id      = s.StudentId,
                    roll    = s.RollNo,
                    name    = s.StudentName,
                    gender  = s.Gender,
                    marks   = s.Marks,
                    absent  = s.IsAbsent,
                    hasMark = s.HasMark
                })
            });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveMarks([FromBody] ExamMarksSaveRequest request)
        {
            var result = await _exam.SaveMarksAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success      = result.Success,
                message      = result.Message,
                saved        = result.Saved,
                markedAbsent = result.MarkedAbsent,
                isFinalized  = result.IsFinalized
            });
        }

        [HttpPost]
        [HasPermission("exams.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ReopenSheet(int examId, int classId, int subjectId, string? section)
        {
            // exams.manage alone is not enough here — the page tells teachers to ask
            // an admin, so the server has to hold that line.
            if (!await IsAdminAsync())
                return Json(new { success = false, message = "Only a school admin can reopen a finalized sheet." });

            var result = await _exam.ReopenSheetAsync(
                examId, classId, subjectId, section, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message });
        }
    }
}
