using educore.Helpers;
using educore.Models;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Students.Controllers
{
    /// <summary>
    /// Certificates (/students/certificates): Bonafide (a current student) and Character
    /// (current or former), numbered and kept in a register like the TC.
    /// Seeing and printing needs students.view; issuing and voiding students.manage.
    /// </summary>
    [Area("Students")]
    [HasPermission("students.view")]
    public class CertificateController : Controller
    {
        private readonly ICertificateService _certs;
        private readonly ISchoolSettingsService _settings;

        public CertificateController(ICertificateService certs, ISchoolSettingsService settings)
        {
            _certs = certs;
            _settings = settings;
        }

        [Route("students/certificates")]
        public async Task<IActionResult> Index()
        {
            ViewBag.CanIssue = await HasPermissionAttribute.UserHasAsync(this, "students.manage");
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Search(string? q)
        {
            if (string.IsNullOrWhiteSpace(q) || q.Trim().Length < 2) return Json(Array.Empty<object>());
            var rows = await _certs.SearchStudentsAsync(q, TenantId(), SchoolId(), UserId());
            return Json(rows.Select(s => new
            {
                id = s.StudentId, name = s.StudentName, adm = s.AdmissionNo, cls = s.ClassName, sec = s.Section,
                father = s.GuardianName, mobile = s.Mobile, current = s.IsCurrent, status = s.Status
            }));
        }

        [HttpGet]
        public async Task<IActionResult> List(string? type, string? q)
        {
            var rows = await _certs.GetListAsync(string.IsNullOrWhiteSpace(type) ? null : type, q?.Trim(), TenantId(), SchoolId(), UserId());
            return Json(rows.Select(c => new
            {
                id = c.CertId, no = c.CertNo, type = c.CertType, name = c.StudentName, adm = c.AdmissionNo, cls = c.ClassDisplay,
                purpose = c.Purpose, conduct = c.Conduct, date = Dates.Show(c.IssueDate), isVoid = c.IsVoid, voidReason = c.VoidReason
            }));
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Issue([FromBody] IssueRequest req)
        {
            if (req == null || req.StudentId <= 0) return Json(new { success = false, message = "Pick a student." });
            var (ok, msg, id) = await _certs.IssueAsync(req.StudentId, req.Type ?? "", req.Purpose?.Trim(), req.Conduct?.Trim(),
                                                        req.Remarks?.Trim(), TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg, id });
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Void([FromBody] VoidRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.Reason)) return Json(new { success = false, message = "Give a reason." });
            var (ok, msg) = await _certs.VoidAsync(req.Id, req.Reason.Trim(), TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        // ── GET: /students/certificate/Print/5 ── on the school letterhead
        [HttpGet]
        public async Task<IActionResult> Print(int id)
        {
            var c = await _certs.GetAsync(id, TenantId(), SchoolId(), UserId());
            if (c == null) return NotFound();
            var school = await _settings.GetBasicProfileAsync(TenantId(), SchoolId(), UserId())
                         ?? new SchoolManageModel { SchoolName = "Your School" };
            ViewBag.School = school;
            ViewBag.Logo = AbsoluteLogo(school.LogoUrl);
            return View(c);
        }

        public class IssueRequest
        {
            public int     StudentId { get; set; }
            public string? Type      { get; set; }
            public string? Purpose   { get; set; }
            public string? Conduct   { get; set; }
            public string? Remarks   { get; set; }
        }

        public class VoidRequest
        {
            public int     Id     { get; set; }
            public string? Reason { get; set; }
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
