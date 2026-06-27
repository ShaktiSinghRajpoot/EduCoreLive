using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    [HasPermission("registration.view")]
    public class RegistrationController : Controller
    {
        private readonly IRegistrationService _registrationService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly IBaseService _baseService;
        private readonly IEnquiryService _enquiryService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IFeePaymentService _feePaymentService;

        public RegistrationController(
            IRegistrationService registrationService,
            IAdmissionWorkflowService admissionWorkflowService,
            IBaseService baseService,
            IEnquiryService enquiryService,
            ISchoolSettingsService schoolSettingsService,
            IFeePaymentService feePaymentService)
        {
            _registrationService = registrationService;
            _admissionWorkflowService = admissionWorkflowService;
            _baseService = baseService;
            _enquiryService = enquiryService;
            _schoolSettingsService = schoolSettingsService;
            _feePaymentService = feePaymentService;
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
        [HasPermission("registration.manage")]
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
        [HasPermission("registration.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> MarkFeePaid([FromBody] MarkRegistrationFeeRequest req)
        {
            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            var (success, message) = await _registrationService.MarkFeePaidAsync(
                req.EnquiryId, tenantId, schoolId, actionUserId);

            // Flipping the "fee paid" flag must also issue a real receipt — the same
            // way the CRM register modal does. The amount is master data (sum of the
            // Registration-point Fee Heads for the enquiry's class), never client-supplied.
            string? receiptNo = null;
            if (success > 0)
            {
                var enquiry = await _enquiryService.GetEnquiryByIdAsync(req.EnquiryId, tenantId, schoolId, actionUserId);
                if (enquiry != null)
                {
                    decimal regFee = await _schoolSettingsService.GetCollectionPointTotalAsync(
                        enquiry.ClassName ?? string.Empty, enquiry.Session ?? string.Empty,
                        "Registration", tenantId, schoolId, actionUserId);

                    if (regFee > 0)
                    {
                        var (paid, _, rcp) = await _feePaymentService.RecordRegistrationPaymentAsync(
                            req.EnquiryId, regFee,
                            NullIfEmpty(req.PaymentMode) ?? "Cash",
                            NullIfEmpty(req.PaymentReference),
                            "Registration fee",
                            enquiry.Session,
                            tenantId, schoolId, actionUserId);

                        if (paid) receiptNo = rcp;
                    }
                }
            }

            return Json(new { success = success > 0, message, receiptNo });
        }

        // ── Helpers ──────────────────────────────────────────────
        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
