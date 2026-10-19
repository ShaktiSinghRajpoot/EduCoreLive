using educore.Helpers;
using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Exams.Controllers
{
    // Admit cards: pick a published exam, a class and (optionally) a section, and
    // print one card per student with that exam's datesheet. Built live from the
    // student records (the ID card data) and the datesheet; nothing is stored.
    [Area("Exams")]
    [HasPermission("exams.view")]
    [RequiresModule(SchoolModule.Exams)]
    public class AdmitCardController : Controller
    {
        private readonly IExamService _exam;
        private readonly IIdCardService _cards;
        private readonly ISchoolSettingsService _settings;
        private readonly IBaseService _baseService;
        private readonly IFeePaymentService _fees;

        public AdmitCardController(IExamService exam, IIdCardService cards, ISchoolSettingsService settings, IBaseService baseService,
                                   IFeePaymentService fees)
        {
            _exam = exam;
            _cards = cards;
            _settings = settings;
            _baseService = baseService;
            _fees = fees;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // The chooser. Only PUBLISHED exams: a draft datesheet can still change.
        [HttpGet("exams/admit-cards")]
        public async Task<IActionResult> Index()
        {
            var exams = new List<SelectListItem>();

            List<SelectListItem> sessions;
            try
            {
                sessions = await _baseService.GetSelectListAsync(
                    "config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            }
            catch { sessions = new List<SelectListItem>(); }

            foreach (var sn in sessions)
            {
                if (!int.TryParse(sn.Value, out var yearId)) continue;
                var data = await _exam.GetExamsAsync(TenantId(), SchoolId(), UserId(), yearId);
                foreach (var e in data.Exams.Where(e => e.Status == "Published"))
                {
                    exams.Add(new SelectListItem
                    {
                        Value = e.ExamId.ToString(),
                        Text  = e.ExamName + " (" + (string.IsNullOrWhiteSpace(data.AcademicYearName) ? sn.Text : data.AcademicYearName) + ")"
                    });
                }
            }

            ViewBag.Exams = exams;
            return View();
        }

        // Classes the exam covers.
        [HttpGet]
        public async Task<IActionResult> Classes(int examId)
        {
            var classes = await _exam.GetExamClassesAsync(examId, TenantId(), SchoolId(), UserId());
            return Json(classes.Select(c => new { id = c.AcademicClassId, name = c.ClassName }));
        }

        // Sections of that class which have students (same list the ID cards use).
        [HttpGet]
        public async Task<IActionResult> Sections(int examId, int classId)
        {
            var sheet = await _exam.GetDatesheetAsync(classId, examId, TenantId(), SchoolId(), UserId());
            var className = sheet.Rows.Select(r => r.ClassName).FirstOrDefault();
            if (string.IsNullOrWhiteSpace(className)) return Json(Array.Empty<string>());

            var sections = await _cards.GetClassSectionsAsync(className, sheet.AcademicYearName, TenantId(), SchoolId(), UserId());
            // An exam held for some sections only (9-A, 9-B) offers only those.
            var held = await ExamSectionsAsync(examId, classId);
            if (held.Count > 0)
                sections = sections.Where(x => held.Contains(x.Trim(), StringComparer.OrdinalIgnoreCase)).ToList();
            return Json(sections);
        }

        // Sections an exam is held for in one class; empty = the whole class.
        private async Task<List<string>> ExamSectionsAsync(int examId, int classId)
        {
            var exam = await _exam.GetExamAsync(examId, TenantId(), SchoolId(), UserId());
            return exam?.Classes.FirstOrDefault(c => c.AcademicClassId == classId)?.Sections
                       .Select(x => x.Trim()).ToList()
                   ?? new List<string>();
        }

        // The print sheet.
        [HttpGet]
        // holdDues = true: students with fees fallen due are left out and listed on
        // screen instead, so the office can hand those cards over once fees are paid
        // (QA BUG-075; a common school practice, so it is a choice, not a rule).
        public async Task<IActionResult> Print(int examId, int classId, string? section, string? format, bool holdDues = false)
        {
            var exam  = await _exam.GetExamAsync(examId, TenantId(), SchoolId(), UserId());
            var sheet = await _exam.GetDatesheetAsync(classId, examId, TenantId(), SchoolId(), UserId());
            var className = sheet.Rows.Select(r => r.ClassName).FirstOrDefault();

            var students = string.IsNullOrWhiteSpace(className)
                ? new List<IdCardStudent>()
                : await _cards.GetClassCardsAsync(className, string.IsNullOrWhiteSpace(section) ? null : section,
                                                  sheet.AcademicYearName, TenantId(), SchoolId(), UserId());

            var school = await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId())
                         ?? new SchoolManageModel { SchoolName = "Your School" };

            // Only the sections the exam is held for (9-C gets no card for a 9-A / 9-B exam).
            var examSections = exam?.Classes.FirstOrDefault(c => c.AcademicClassId == classId)?.Sections ?? new List<string>();
            if (examSections.Count > 0)
                students = students.Where(st => examSections.Any(h => string.Equals(h.Trim(), (st.Section ?? "").Trim(), StringComparison.OrdinalIgnoreCase))).ToList();

            // Section by section, then roll order, so a class set is handed out in order.
            students = students
                .OrderBy(s => s.Section)
                .ThenBy(s => int.TryParse(s.RollNo, out var n) ? n : int.MaxValue)
                .ThenBy(s => s.StudentName)
                .ToList();

            var held = new List<AdmitCardHeld>();
            if (holdDues && students.Count > 0)
            {
                var dues = await StudentsWithDuesAsync(className!);
                foreach (var s in students)
                    if (dues.TryGetValue(s.StudentId, out var amount))
                        held.Add(new AdmitCardHeld { Student = s, Outstanding = amount });
                students = students.Where(s => !dues.ContainsKey(s.StudentId)).ToList();
            }

            var model = new AdmitCardPrintModel
            {
                Students    = students,
                Held        = held,
                Papers      = sheet.Rows,
                School      = school,
                LogoUrl     = AbsoluteLogo(school.LogoUrl),
                ExamName    = exam?.ExamName ?? sheet.Rows.Select(r => r.ExamName).FirstOrDefault() ?? "Examination",
                SessionName = sheet.AcademicYearName,
                Format      = format is "Compact" or "FullPage" ? format : "Classic"
            };
            return View("Print", model);
        }

        // Student id -> fees fallen due and unpaid, for one class (the Due Reminders list).
        private async Task<Dictionary<int, decimal>> StudentsWithDuesAsync(string className)
        {
            var result = new Dictionary<int, decimal>();
            for (int page = 1; page <= 20; page++)
            {
                var list = await _fees.GetFeeDueListAsync(
                    new FeeDueItem { FilterClass = className, Page = page, PageSize = 200 },
                    TenantId(), SchoolId(), UserId());
                foreach (var d in list.Items) result[d.StudentId] = d.TotalOutstanding;
                if (list.Items.Count < 200) break;
            }
            return result;
        }

        private string? AbsoluteLogo(string? logoUrl)
        {
            if (string.IsNullOrWhiteSpace(logoUrl)) return null;
            if (logoUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return logoUrl;
            var slash = logoUrl.StartsWith('/') ? "" : "/";
            return $"{Request.Scheme}://{Request.Host}{slash}{logoUrl}";
        }
    }
}
