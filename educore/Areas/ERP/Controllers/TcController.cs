using educore.Helpers;
using educore.Models;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    // Transfer Certificate: issue, reprint and the register. Sits on the student-exit
    // flow — only a student who has left (and cleared dues) can be issued a TC.
    [Area("ERP")]
    [HasPermission("students.view")]
    public class TcController : Controller
    {
        private readonly ITransferCertificateService _tc;
        private readonly ISchoolSettingsService _settings;

        public TcController(ITransferCertificateService tc, ISchoolSettingsService settings)
        {
            _tc = tc;
            _settings = settings;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // Issue a certificate. The proc holds the dues gate and the one-per-student
        // rule, so its message is what the office sees.
        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Issue([FromBody] TcIssueRequest request)
        {
            var result = await _tc.IssueAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new { success = result.Success, message = result.Message, tcId = result.TcId, tcNo = result.TcNo });
        }

        // The printable certificate. Opens full-page and prints itself. Serving it
        // marks it printed, so every reprint after the first is stamped DUPLICATE.
        [HttpGet]
        public async Task<IActionResult> Print(int id)
        {
            var cert = await _tc.GetForPrintAsync(id, TenantId(), SchoolId(), UserId());
            if (cert == null) return NotFound();

            var model = await BuildPrintModel(cert, isPreview: false);
            return View("Print", model);
        }

        // Format preview for the Documents page and the issue modal — sample data, no
        // record written, never stamps DUPLICATE.
        [HttpGet]
        public async Task<IActionResult> Preview(string format = "Standard")
        {
            var model = await BuildPrintModel(SampleCertificate(format), isPreview: true);
            return View("Print", model);
        }

        // The issued-TC register.
        [HttpGet]
        public async Task<IActionResult> Register(TcListModel query)
        {
            await _tc.GetListAsync(query, TenantId(), SchoolId(), UserId());
            return View(query);
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Void([FromBody] TcVoidRequest request)
        {
            var (success, message) = await _tc.VoidAsync(request, TenantId(), SchoolId(), UserId());
            return Json(new { success, message });
        }

        // Loads the school letterhead (name/address/logo) so the print looks real,
        // and turns a relative logo path into an absolute one — the print popup is
        // about:blank and cannot resolve a relative URL.
        private async Task<TcPrintModel> BuildPrintModel(TransferCertificate cert, bool isPreview)
        {
            var school = await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId())
                         ?? new SchoolManageModel { SchoolName = "Your School" };

            return new TcPrintModel
            {
                Tc        = cert,
                School    = school,
                LogoUrl   = AbsoluteLogo(school.LogoUrl),
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

        private static TransferCertificate SampleCertificate(string format) => new()
        {
            Format        = format is "Board" or "Basic" ? format : "Basic",
            TcNo          = "TC-0000-0000",
            IssueDate     = DateOnly.FromDateTime(DateTime.Today),
            AdmissionNo   = "ADM-0000-0001",
            StudentName   = "Aarav Sharma",
            Gender        = "Male",
            Dob           = new DateOnly(2013, 4, 12),
            FatherName    = "Rajesh Sharma",
            MotherName    = "Priya Sharma",
            ClassName     = "Class V",
            Section        = "A",
            AcademicYear  = "2026-2027",
            AdmissionDate = new DateOnly(2021, 4, 1),
            DateOfLeaving = DateOnly.FromDateTime(DateTime.Today),
            Religion      = "Hindu",
            Category      = "General",
            Nationality   = "Indian",
            Address       = "12, Green Park, New Delhi",
            UdiseNo       = "1234567890",
            ReasonForLeaving = "Family relocating to another city",
            Conduct       = "Good",
            Result        = "Qualified for promotion to Class VI",
            Remarks       = "Sample certificate — preview only.",
            // Board extras
            ExamResult      = "Annual Examination 2025-26 — Passed",
            FailedStatus    = "No",
            SubjectsStudied = "English, Hindi, Mathematics, EVS, Computer",
            FeesPaidUpto    = "March 2026",
            WorkingDays     = 220,
            DaysPresent     = 210,
            Activities      = "Scouts; School football team",
            ApplicationDate = DateOnly.FromDateTime(DateTime.Today.AddDays(-2))
        };
    }
}
