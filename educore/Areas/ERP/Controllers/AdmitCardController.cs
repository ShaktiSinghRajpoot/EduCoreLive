using educore.Helpers;
using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    // Admit cards: pick a published exam, a class and (optionally) a section, and
    // print one card per student with that exam's datesheet. Built live from the
    // student records (the ID card data) and the datesheet; nothing is stored.
    [Area("ERP")]
    [HasPermission("exams.view")]
    [RequiresModule(SchoolModule.Exams)]
    public class AdmitCardController : Controller
    {
        private readonly IExamService _exam;
        private readonly IIdCardService _cards;
        private readonly ISchoolSettingsService _settings;
        private readonly IBaseService _baseService;

        public AdmitCardController(IExamService exam, IIdCardService cards, ISchoolSettingsService settings, IBaseService baseService)
        {
            _exam = exam;
            _cards = cards;
            _settings = settings;
            _baseService = baseService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // The chooser. Only PUBLISHED exams: a draft datesheet can still change.
        [HttpGet]
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
            return Json(sections);
        }

        // The print sheet.
        [HttpGet]
        public async Task<IActionResult> Print(int examId, int classId, string? section, string? format)
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

            var model = new AdmitCardPrintModel
            {
                Students    = students,
                Papers      = sheet.Rows,
                School      = school,
                LogoUrl     = AbsoluteLogo(school.LogoUrl),
                ExamName    = exam?.ExamName ?? sheet.Rows.Select(r => r.ExamName).FirstOrDefault() ?? "Examination",
                SessionName = sheet.AcademicYearName,
                Format      = format is "Compact" or "FullPage" ? format : "Classic"
            };
            return View("Print", model);
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
