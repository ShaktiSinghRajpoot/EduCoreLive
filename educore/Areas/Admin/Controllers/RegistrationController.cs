using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    public class RegistrationController : Controller
    {
        private readonly IRegistrationService _registrationService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly IBaseService _baseService;

        public RegistrationController(
            IRegistrationService registrationService,
            IAdmissionWorkflowService admissionWorkflowService,
            IBaseService baseService)
        {
            _registrationService = registrationService;
            _admissionWorkflowService = admissionWorkflowService;
            _baseService = baseService;
        }

        // ── GET: /Admin/Registration/Index ───────────────────────
        [HttpGet]
        public async Task<IActionResult> Index()
        {
            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, userId);

            var model = new RegistrationPageModel
            {
                Stats                 = await _registrationService.GetStatsAsync(tenantId, schoolId, userId),
                RegistrationFeeEnabled = workflow.EnableRegistration && workflow.EnableRegistrationFee
            };

            try {
                model.AvailableSessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            }
            catch { /* empty is acceptable */ }
            try { model.AvailableClasses = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class"); }
            catch { /* empty is acceptable */ }

            return View(model);
        }

        // ── GET: /Admin/Registration/GetRegistrationsData (AJAX) ─
        [HttpGet]
        public async Task<IActionResult> GetRegistrationsData(
            int page = 1, int pageSize = 10,
            string? search = null, string? session = null,
            string? className = null, string? feeStatus = null)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), userId = UserId();

            var (rows, totalCount) = await _registrationService.GetRegistrationsAsync(
                tenantId, schoolId, userId, page, pageSize,
                NullIfEmpty(search), NullIfEmpty(session), NullIfEmpty(className), NullIfEmpty(feeStatus));

            var stats = await _registrationService.GetStatsAsync(tenantId, schoolId, userId);

            int totalPages = totalCount > 0 ? (int)Math.Ceiling((double)totalCount / pageSize) : 1;

            return Json(new
            {
                success = true,
                page,
                pageSize,
                totalCount,
                totalPages,
                stats = new
                {
                    totalRegistered = stats.TotalRegistered,
                    feeCollected    = stats.FeeCollected,
                    feePending      = stats.FeePending,
                    converted       = stats.Converted
                },
                rows = rows.Select(r => new
                {
                    enquiryId           = r.EnquiryId,
                    registrationNumber  = r.RegistrationNumber,
                    registrationDate    = r.RegistrationDateDisplay,
                    registrationFeePaid = r.RegistrationFeePaid,
                    studentName         = r.StudentName,
                    className           = r.ClassName,
                    session             = r.Session,
                    parentName          = r.ParentName,
                    mobile              = r.Mobile,
                    status              = r.Status,
                    isAdmitted          = r.IsAdmitted
                })
            });
        }

        // ── POST: /Admin/Registration/Cancel (AJAX) ──────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Cancel([FromBody] CancelRegistrationRequest req)
        {
            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            var (success, message) = await _registrationService.CancelRegistrationAsync(
                req.EnquiryId, NullIfEmpty(req.Reason), TenantId(), SchoolId(), UserId());

            return Json(new { success = success > 0, message });
        }

        // ── POST: /Admin/Registration/MarkFeePaid (AJAX) ─────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> MarkFeePaid([FromBody] MarkRegistrationFeeRequest req)
        {
            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            var (success, message) = await _registrationService.MarkFeePaidAsync(
                req.EnquiryId, TenantId(), SchoolId(), UserId());

            return Json(new { success = success > 0, message });
        }

        // ── Helpers ──────────────────────────────────────────────
        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
