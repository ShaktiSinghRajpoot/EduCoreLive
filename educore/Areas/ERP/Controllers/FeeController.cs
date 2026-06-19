using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    public class FeeController : Controller
    {
        private readonly IBaseService _baseService;
        private readonly IAdmissionService _admissionService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IFeePaymentService _feePaymentService;

        public FeeController(
            IBaseService baseService,
            IAdmissionService admissionService,
            ISchoolSettingsService schoolSettingsService,
            IFeePaymentService feePaymentService)
        {
            _baseService = baseService;
            _admissionService = admissionService;
            _schoolSettingsService = schoolSettingsService;
            _feePaymentService = feePaymentService;
        }

        // ── Pages ────────────────────────────────────────────────
        public IActionResult ManageFee() => View();
        public IActionResult InventoryItem() => View();
        public IActionResult PurchaseEntry() => View();

        // ── GET: /ERP/Fee/GetSessions ────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetSessions()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            return Json(items.Select(x => x.Text).ToList());
        }

        // ── GET: /ERP/Fee/GetClasses ─────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetClasses(string? session = null)
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class");
            return Json(items.Select(x => x.Text).ToList());
        }

        // ── GET: /ERP/Fee/GetSections ────────────────────────────
        // Sections are configured per class + year in Academic Setup.
        [HttpGet]
        public async Task<IActionResult> GetSections(string session, string className)
        {
            if (string.IsNullOrWhiteSpace(session) || string.IsNullOrWhiteSpace(className))
                return Json(Array.Empty<string>());

            int ayId = await ResolveAcademicYearIdAsync(session);
            if (ayId <= 0) return Json(Array.Empty<string>());

            var setup = await _schoolSettingsService.GetAcademicSetupAsync(TenantId(), SchoolId(), ayId, UserId());

            var sections = new List<string>();
            if (setup?.ClassSections != null)
            {
                var key = setup.ClassSections.Keys.FirstOrDefault(
                    k => k.Equals(className.Trim(), StringComparison.OrdinalIgnoreCase));
                if (key != null) sections = setup.ClassSections[key];
            }

            return Json(sections);
        }

        // ── GET: /ERP/Fee/GetStudents ────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetStudents(string session, string className, string section)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(section))
                return Json(Array.Empty<object>());

            var (rows, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 500,
                filterClass: className.Trim(),
                filterSection: section.Trim(),
                filterYear: NullIfEmpty(session));

            return Json(rows.Select(s => new
            {
                id    = s.StudentId,
                admNo = s.AdmissionNo,
                name  = s.StudentName,
                roll  = s.RollNo
            }));
        }

        // ── GET: /ERP/Fee/FindByAdmission ────────────────────────
        [HttpGet]
        public async Task<IActionResult> FindByAdmission(string session, string admissionNo)
        {
            if (string.IsNullOrWhiteSpace(admissionNo))
                return Json((object?)null);

            var (rows, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 50,
                search: admissionNo.Trim(),
                filterYear: NullIfEmpty(session));

            var match = rows.FirstOrDefault(s =>
                string.Equals(s.AdmissionNo, admissionNo.Trim(), StringComparison.OrdinalIgnoreCase));

            if (match == null)
                return Json((object?)null);

            return Json(new
            {
                student   = new { id = match.StudentId, admNo = match.AdmissionNo, name = match.StudentName, roll = match.RollNo },
                className = match.ClassName,
                section   = match.Section
            });
        }

        // ── GET: /ERP/Fee/GetStudentDues ─────────────────────────
        // Returns the student's outstanding dues grouped into the counter's cycle
        // tabs (Monthly / Quarterly / Yearly). Reads core.student_ledger.
        [HttpGet]
        public async Task<IActionResult> GetStudentDues(int studentId)
        {
            var dues = await _feePaymentService.GetStudentDuesAsync(studentId, TenantId(), SchoolId(), UserId());
            var today = DateOnly.FromDateTime(DateTime.Today);

            object Map(IEnumerable<EduCoreDataAccessLayer.Models.Admin.StudentDueItem> items) =>
                items.Select(d => new
                {
                    id       = d.LedgerId,
                    label    = string.IsNullOrWhiteSpace(d.InstallmentLabel)
                                 ? d.FeeHeadName
                                 : $"{d.FeeHeadName} — {d.InstallmentLabel}",
                    dueDate  = d.DueDate?.ToString("yyyy-MM-dd"),
                    amount   = d.Outstanding,
                    overdue  = d.DueDate.HasValue && d.DueDate.Value < today
                }).ToList();

            // Monthly / Quarterly buckets keep their cycle; everything else (Yearly,
            // Half Yearly, One Time, Annual) collapses into the Yearly tab.
            return Json(new
            {
                Monthly   = Map(dues.Where(d => Cycle(d.Frequency) == "Monthly")),
                Quarterly = Map(dues.Where(d => Cycle(d.Frequency) == "Quarterly")),
                Yearly    = Map(dues.Where(d => Cycle(d.Frequency) == "Yearly"))
            });
        }

        // ── POST: /ERP/Fee/RecordPayment ─────────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> RecordPayment([FromBody] RecordPaymentRequest req)
        {
            if (req == null || req.StudentId <= 0 || req.Amount <= 0)
                return Json(new { success = false, message = "Invalid payment request." });

            var (ok, msg, receiptNo) = await _feePaymentService.RecordPaymentAsync(
                req.StudentId, req.Amount,
                NullIfEmpty(req.Mode) ?? "Cash",
                NullIfEmpty(req.Reference),
                NullIfEmpty(req.Remarks),
                NullIfEmpty(req.Session),
                TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = msg, receiptNo });
        }

        public class RecordPaymentRequest
        {
            public int     StudentId { get; set; }
            public decimal Amount    { get; set; }
            public string? Mode      { get; set; }
            public string? Reference { get; set; }
            public string? Remarks   { get; set; }
            public string? Session   { get; set; }
        }

        // ── Helpers ──────────────────────────────────────────────
        private static string Cycle(string? frequency) => frequency switch
        {
            "Monthly"   => "Monthly",
            "Quarterly" => "Quarterly",
            _           => "Yearly"
        };

        private async Task<int> ResolveAcademicYearIdAsync(string session)
        {
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            var ay = ayItems.FirstOrDefault(x => string.Equals(x.Text, session, StringComparison.OrdinalIgnoreCase));
            return ay != null && int.TryParse(ay.Value, out var id) ? id : 0;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
