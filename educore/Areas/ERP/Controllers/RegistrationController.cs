using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
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

        // ── GET: /ERP/Registration/Index ───────────────────────
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
                model.AvailableSessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            }
            catch { /* empty is acceptable */ }
            try { model.AvailableClasses = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString()); }
            catch { /* empty is acceptable */ }

            return View(model);
        }

        // ── GET: /ERP/Registration/GetRegistrationsData (AJAX) ─
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
                    isAdmitted          = r.IsAdmitted,
                    receiptNo           = r.ReceiptNo,
                    feeAmount           = r.FeeAmount,
                    settledAmount       = r.SettledAmount,
                    balanceAmount       = r.BalanceAmount,
                    // Every receipt, so a fee paid in parts keeps every slip
                    // reprintable (and cancellable) from this list.
                    receipts            = r.Receipts.Select(x => new
                    {
                        receiptNo = x.ReceiptNo,
                        date      = x.Date,
                        amount    = x.Amount,
                        discount  = x.Discount,
                        mode      = x.Mode,
                        cancelled = x.Cancelled
                    })
                })
            });
        }

        // ── POST: /ERP/Registration/Cancel (AJAX) ──────────────
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

        // ── POST: /ERP/Registration/MarkFeePaid (AJAX) ─────────
        [HttpPost]
        // Writes a receipt, so it is a money action (the class needs registration.view).
        [HasPermission("fees.collect")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> MarkFeePaid([FromBody] MarkRegistrationFeeRequest req)
        {
            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            // This used to flip a "fee paid" flag first (its own transaction) and
            // only then try to write a receipt -- which it skipped whenever the fee
            // lookup came back 0, leaving a registration marked paid with no money
            // behind it. Now the receipt IS the action: nothing is marked, and paid
            // is worked out from the receipts by the database.
            var enquiry = await _enquiryService.GetEnquiryByIdAsync(req.EnquiryId, tenantId, schoolId, actionUserId);
            if (enquiry == null)
                return Json(new { success = false, message = "Registration not found." });

            // The agreed fee: frozen on the enquiry at the first receipt; before
            // that, the Registration-point total for the class -- the SAME resolved
            // total the register modal shows (class-wise structure, else the fee
            // head's default). The class-wise-only lookup returned 0 for a school
            // using plain fee heads.
            var (agreed, _, owed, _) = await _feePaymentService.GetRegistrationFeeSummaryAsync(
                req.EnquiryId, tenantId, schoolId, actionUserId);
            decimal regFee = agreed > 0
                ? agreed
                : await _schoolSettingsService.GetCollectionPointResolvedTotalAsync(
                      enquiry.ClassName ?? string.Empty, enquiry.Session ?? string.Empty,
                      "Registration", tenantId, schoolId, actionUserId);
            if (agreed <= 0) owed = regFee;

            if (regFee <= 0)
                return Json(new { success = false, message = "No registration fee is set up for this class. Add a Registration-point fee head first." });
            if (owed <= 0)
                return Json(new { success = false, message = "Nothing is outstanding on this registration." });

            // A part payment is allowed. No amount means "whatever is still owed".
            // The procedure refuses more than is outstanding.
            decimal cash = req.CollectAmount is > 0 ? req.CollectAmount.Value : owed;

            var (paid, message, receiptNo, balance) = await _feePaymentService.RecordRegistrationPaymentAsync(
                req.EnquiryId, cash,
                NullIfEmpty(req.PaymentMode) ?? "Cash",
                NullIfEmpty(req.PaymentReference),
                "Registration fee",
                enquiry.Session,
                tenantId, schoolId, actionUserId,
                feeAmount: regFee);

            return Json(new { success = paid, message, receiptNo = paid ? receiptNo : null, balance });
        }

        // ── GET: /ERP/Registration/FeeSummary ────────────────────
        // What this registration's fee stands at, so the collect dialog can show the
        // family what is owed before anyone types an amount. "Mark fee collected"
        // used to post the full fee the moment it was clicked, with nothing shown
        // and nothing to confirm.
        [HttpGet]
        // Read-only balance for the collect dialog; registration.view (class level) is
        // enough -- fees.view hid the balance from a desk allowed to collect.
        public async Task<IActionResult> FeeSummary(int enquiryId)
        {
            if (enquiryId <= 0) return Json(new { success = false, message = "Invalid request." });

            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            var (fee, settled, balance, name) =
                await _feePaymentService.GetRegistrationFeeSummaryAsync(enquiryId, tenantId, schoolId, actionUserId);

            // Nothing agreed yet — this registration predates the fee being recorded,
            // so fall back to the configured Registration-point total for its class.
            if (fee <= 0)
            {
                var enquiry = await _enquiryService.GetEnquiryByIdAsync(enquiryId, tenantId, schoolId, actionUserId);
                if (enquiry != null)
                {
                    fee = await _schoolSettingsService.GetCollectionPointResolvedTotalAsync(
                        enquiry.ClassName ?? string.Empty, enquiry.Session ?? string.Empty,
                        "Registration", tenantId, schoolId, actionUserId);
                    balance = fee - settled;
                    if (balance < 0) balance = 0;
                    if (string.IsNullOrWhiteSpace(name)) name = enquiry.StudentName ?? string.Empty;
                }
            }

            return Json(new { success = true, studentName = name, fee, settled, balance });
        }

        // ── Helpers ──────────────────────────────────────────────
        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
