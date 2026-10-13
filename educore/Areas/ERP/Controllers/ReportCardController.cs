using educore.Helpers;
using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    // Report cards: pick an exam whose RESULTS are published, a class and
    // (optionally) a section, and print one report card per student. The class
    // and section lists come from the admit-card page (same exam / class rules).
    [Area("ERP")]
    [HasPermission("exams.view")]
    [RequiresModule(SchoolModule.Exams)]
    public class ReportCardController : Controller
    {
        private readonly IExamService _exam;
        private readonly IExamResultService _results;
        private readonly IIdCardService _cards;
        private readonly ICertificateService _certs;
        private readonly ISchoolSettingsService _settings;
        private readonly IBaseService _baseService;

        public ReportCardController(IExamService exam, IExamResultService results, IIdCardService cards,
                                    ICertificateService certs, ISchoolSettingsService settings, IBaseService baseService)
        {
            _exam = exam;
            _results = results;
            _cards = cards;
            _certs = certs;
            _settings = settings;
            _baseService = baseService;
        }

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
                foreach (var e in data.Exams.Where(e => e.ResultsStatus == "Published"))
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

        [HttpGet]
        public async Task<IActionResult> Print(int examId, int classId, string? section)
        {
            var sheet = await _results.GetClassResultAsync(examId, classId, string.IsNullOrWhiteSpace(section) ? null : section,
                                                           TenantId(), SchoolId(), UserId());
            if (sheet == null) return NotFound();
            if (sheet.ResultsStatus != "Published")
                return Content("The results of this exam are not published yet. Publish them on the Result Sheet first.");

            var records = await _cards.GetClassCardsAsync(sheet.ClassName, string.IsNullOrWhiteSpace(section) ? null : section,
                                                          sheet.AcademicYearName, TenantId(), SchoolId(), UserId());
            var extras = await _certs.GetReportCardExtrasAsync(sheet.Students.Select(s => s.StudentId), sheet.AcademicYearName,
                                                               TenantId(), SchoolId(), UserId());
            var scale = await _results.GetGradeScaleAsync(TenantId(), SchoolId(), UserId());
            var school = await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId())
                         ?? new SchoolManageModel { SchoolName = "Your School" };

            // Section by section, then roll order, so a class set is handed out in order.
            sheet.Students = sheet.Students
                .OrderBy(s => s.Section)
                .ThenBy(s => int.TryParse(s.RollNo, out var n) ? n : int.MaxValue)
                .ThenBy(s => s.StudentName)
                .ToList();

            var model = new ReportCardPrintModel
            {
                Sheet   = sheet,
                School  = school,
                LogoUrl = AbsoluteLogo(school.LogoUrl),
                Records = records.GroupBy(r => r.StudentId).ToDictionary(g => g.Key, g => g.First()),
                Extras  = extras
            };
            foreach (var b in scale.Bands.Where(b => !string.IsNullOrWhiteSpace(b.Remark)))
                model.GradeRemarks[b.Label] = b.Remark!;

            return View("Print", model);
        }

        private string? AbsoluteLogo(string? logoUrl)
        {
            if (string.IsNullOrWhiteSpace(logoUrl)) return null;
            if (logoUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return logoUrl;
            var slash = logoUrl.StartsWith('/') ? "" : "/";
            return $"{Request.Scheme}://{Request.Host}{slash}{logoUrl}";
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
