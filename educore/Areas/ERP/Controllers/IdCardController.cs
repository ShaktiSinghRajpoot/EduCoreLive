using educore.Helpers;
using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    // Student ID cards: pick a class and print the whole batch on A4 sheets, or
    // print one card. Cards are generated live from student data — nothing frozen.
    [Area("ERP")]
    [HasPermission("students.view")]
    public class IdCardController : Controller
    {
        private readonly IIdCardService _cards;
        private readonly ISchoolSettingsService _settings;
        private readonly IBaseService _baseService;

        public IdCardController(IIdCardService cards, ISchoolSettingsService settings, IBaseService baseService)
        {
            _cards = cards;
            _settings = settings;
            _baseService = baseService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // The chooser: pick class / year / section / layout, then open the sheet.
        [HttpGet]
        public async Task<IActionResult> Index()
        {
            try { ViewBag.ClassList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.ClassList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }

            try { ViewBag.YearList = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString()); }
            catch { ViewBag.YearList = new List<Microsoft.AspNetCore.Mvc.Rendering.SelectListItem>(); }

            ViewBag.DefaultFormat = await _settings.GetIdCardFormatAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        // Sections that have students in a class — fills the chooser's Section list.
        [HttpGet]
        public async Task<IActionResult> Sections(string @class, string? year)
        {
            var sections = await _cards.GetClassSectionsAsync(@class, year, TenantId(), SchoolId(), UserId());
            return Json(sections);
        }

        // The bulk sheet for one class.
        [HttpGet]
        public async Task<IActionResult> Print(string @class, string? section, string? year, string? format)
        {
            var students = await _cards.GetClassCardsAsync(@class, section, year, TenantId(), SchoolId(), UserId());
            var model = await BuildModel(students, format, isPreview: false);
            return View("Print", model);
        }

        // One student's card (from the directory / dashboard).
        [HttpGet]
        public async Task<IActionResult> Single(int id, string? format)
        {
            var one = await _cards.GetOneAsync(id, TenantId(), SchoolId(), UserId());
            var list = one == null ? new List<IdCardStudent>() : new List<IdCardStudent> { one };
            var model = await BuildModel(list, format, isPreview: false);
            return View("Print", model);
        }

        // Layout preview for the Documents page — sample students, nothing read.
        [HttpGet]
        public async Task<IActionResult> Preview(string format = "Portrait")
        {
            var model = await BuildModel(SampleStudents(), format, isPreview: true);
            return View("Print", model);
        }

        private async Task<IdCardPrintModel> BuildModel(List<IdCardStudent> students, string? format, bool isPreview)
        {
            var school = await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId())
                         ?? new SchoolManageModel { SchoolName = "Your School" };

            var fmt = format is "Portrait" or "Landscape"
                ? format
                : await _settings.GetIdCardFormatAsync(TenantId(), SchoolId(), UserId());

            return new IdCardPrintModel
            {
                Students  = students,
                School    = school,
                LogoUrl   = AbsoluteLogo(school.LogoUrl),
                Format    = fmt,
                IsPreview = isPreview
            };
        }

        private string? AbsoluteLogo(string? logoUrl)
        {
            if (string.IsNullOrWhiteSpace(logoUrl)) return null;
            if (logoUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return logoUrl;
            var slash = logoUrl.StartsWith('/') ? "" : "/";
            return $"{Request.Scheme}://{Request.Host}{slash}{logoUrl}";
        }

        private static List<IdCardStudent> SampleStudents() => new()
        {
            new IdCardStudent { StudentName = "Aarav Sharma", AdmissionNo = "ADM-0001", RollNo = "01",
                ClassName = "Class V", Section = "A", AcademicYear = "2026-2027",
                Dob = new DateOnly(2015, 4, 12), BloodGroup = "O+", Gender = "Male",
                GuardianName = "Rajesh Sharma", Mobile = "9810000001", Address = "12, Green Park, New Delhi" },
            new IdCardStudent { StudentName = "Bhavya Gupta", AdmissionNo = "ADM-0002", RollNo = "02",
                ClassName = "Class V", Section = "A", AcademicYear = "2026-2027",
                Dob = new DateOnly(2015, 7, 8), BloodGroup = "B+", Gender = "Female",
                GuardianName = "Anil Gupta", Mobile = "9810000002", Address = "5, Rose Lane, New Delhi" }
        };
    }
}
