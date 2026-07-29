using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    [HasPermission("enquiry.view")]
    public class EnquiryController : Controller
    {
        private readonly IEnquiryService _enquiryService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly IFeePaymentService _feePaymentService;
        private readonly IBaseService _baseService;

        public EnquiryController(
            IEnquiryService enquiryService,
            ISchoolSettingsService schoolSettingsService,
            IAdmissionWorkflowService admissionWorkflowService,
            IFeePaymentService feePaymentService,
            IBaseService baseService)
        {
            _enquiryService = enquiryService;
            _schoolSettingsService = schoolSettingsService;
            _admissionWorkflowService = admissionWorkflowService;
            _feePaymentService = feePaymentService;
            _baseService = baseService;
        }

        // ── GET: /ERP/Enquiry/EnquiryCRM ───────────────────────
        // One EnquiryCrmPageModel does it all, exactly like StudentList: the bound
        // filters/sort/page arrive on the query string, the service fills Items +
        // TotalCount + KPI. Tenant/school/user come from CLAIMS only.
        [HttpGet]
        public async Task<IActionResult> EnquiryCRM(EnquiryCrmPageModel query)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            // Dropdowns — same pattern as FeeStructure
            query.AvailableSessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear" ,tenantId.ToString(), schoolId.ToString());
            query.AvailableClasses = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", tenantId.ToString(), schoolId.ToString());

            // Counsellors — try loading; empty list is acceptable if not configured
            try { query.AvailableCounsellors = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Counsellor", tenantId.ToString(), schoolId.ToString()); }
            catch { query.AvailableCounsellors = new List<SelectListItem>(); }

            // Admission workflow settings — drive show/hide of the Registration stage.
            query.Workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, actionUserId);

            await _enquiryService.GetEnquiryCrmPageAsync(query, tenantId, schoolId, actionUserId);
            return View(query);
        }

        // ── GET: /ERP/Enquiry/GetFollowups (AJAX) ──────────────
        [HttpGet]
        public async Task<IActionResult> GetFollowups(int enquiryId)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            var followups = await _enquiryService.GetFollowupsAsync(enquiryId, tenantId, schoolId, actionUserId);
            var history = await _enquiryService.GetStatusHistoryAsync(enquiryId, tenantId, schoolId, actionUserId);

            // One ready-to-render timeline instead of two lists the page has to merge.
            // Merging here keeps real DateTimes, so sorting and de-duplicating are exact —
            // the page only had the formatted strings and could do neither reliably.
            var rows = new List<(DateTime At, object Row)>();

            foreach (var f in followups)
                rows.Add((f.FollowupDate, new
                {
                    kind = "followup",
                    at = IstText(f.FollowupDate),
                    timeAgo = f.TimeAgo,
                    followupType = f.FollowupType,
                    typeIcon = f.TypeIcon,
                    outcome = f.Outcome,
                    badgeClass = f.OutcomeBadgeClass,
                    note = f.Notes,
                    statusBefore = f.StatusBefore,
                    statusAfter = f.StatusAfter
                }));

            foreach (var h in history)
            {
                // Logging a follow-up that also changes the status writes BOTH a follow-up
                // row and a status-history row, which showed up as the same event twice.
                // The follow-up entry already shows the transition, so drop the twin.
                // The proc writes the pair inside one transaction, so their timestamps
                // differ only by however long that transaction took.
                bool loggedWithFollowup = followups.Any(f =>
                    f.StatusAfter == h.StatusTo &&
                    Math.Abs((f.FollowupDate - h.CreatedAt).TotalSeconds) <= SameTransactionSeconds);
                if (loggedWithFollowup) continue;

                rows.Add((h.CreatedAt, new
                {
                    kind = "status",
                    at = IstText(h.CreatedAt),
                    statusFrom = h.StatusFrom ?? "Created",
                    statusTo = h.StatusTo,
                    badgeClass = h.StatusToBadgeClass,
                    note = h.ChangeNote
                }));
            }

            return Json(new
            {
                success = true,
                timeline = rows.OrderByDescending(r => r.At).Select(r => r.Row)
            });
        }

        // ── GET: /ERP/Enquiry/GetEnquiry (AJAX) — for edit prefill ──
        [HttpGet]
        public async Task<IActionResult> GetEnquiry(int id)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            var e = await _enquiryService.GetEnquiryByIdAsync(id, tenantId, schoolId, actionUserId);
            if (e == null)
                return Json(new { success = false, message = "Enquiry not found." });

            // Once admitted, corrections must go through Edit Student — the enquiry is locked.
            if (e.AdmissionId.HasValue)
                return Json(new { success = false, locked = true, message = "This enquiry is already admitted. Edit the student record instead." });

            return Json(new
            {
                success = true,
                data = new
                {
                    enquiryId        = e.EnquiryId,
                    studentName      = e.StudentName,
                    gender           = e.Gender,
                    dob              = e.Dob?.ToString("yyyy-MM-dd"),
                    className        = e.ClassName,
                    session          = e.Session,
                    currentSchool    = e.CurrentSchool,
                    currentClass     = e.CurrentClass,
                    interestedStream = e.InterestedStream,
                    fatherName       = e.FatherName,
                    fatherMobile     = e.FatherMobile,
                    motherName       = e.MotherName,
                    motherMobile     = e.MotherMobile,
                    parentEmail      = e.ParentEmail,
                    whatsAppNumber   = e.WhatsAppNumber,
                    city             = e.City,
                    areaLocality     = e.AreaLocality,
                    leadSource       = e.LeadSource,
                    status           = e.Status,
                    referrerName     = e.ReferrerName,
                    referrerMobile   = e.ReferrerMobile,
                    assignedToId     = e.AssignedToId,
                    nextFollowupDate = e.NextFollowupDate?.ToString("yyyy-MM-dd"),
                    transportRequired = e.TransportRequired,
                    notes            = e.Notes
                }
            });
        }

        // ── POST: /ERP/Enquiry/SaveEnquiry ─────────────────────
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveEnquiry(EnquiryModel model)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            // Edit path: correct DETAILS only — never the state-machine / registration fields.
            if (model.EnquiryId > 0)
            {
                var existing = await _enquiryService.GetEnquiryByIdAsync(model.EnquiryId, tenantId, schoolId, actionUserId);
                if (existing != null)
                {
                    // An admitted enquiry is locked — corrections go through Edit Student.
                    if (existing.AdmissionId.HasValue)
                    {
                        TempData["Result"] = "0";
                        TempData["Message"] = "This enquiry is already admitted. Edit the student record instead.";
                        return RedirectToAction(nameof(EnquiryCRM));
                    }

                    // Preserve status & registration so editing can't reset the status
                    // (e.g. Not Interested → New) or wipe a registration number / fee.
                    // These change only through their own actions (status dropdown, Register).
                    model.Status              = existing.Status;
                    model.Priority            = existing.Priority;
                    model.LostReason          = existing.LostReason;
                    model.EstimatedFee        = existing.EstimatedFee;
                    model.RegistrationNumber  = existing.RegistrationNumber;
                    model.RegistrationDate    = existing.RegistrationDate;
                    model.RegistrationFeePaid = existing.RegistrationFeePaid;
                }
            }

            // Primary mobile: use father mobile if main mobile is blank
            if (string.IsNullOrWhiteSpace(model.Mobile) && !string.IsNullOrWhiteSpace(model.FatherMobile))
                model.Mobile = model.FatherMobile;

            if (string.IsNullOrWhiteSpace(model.StudentName) ||
                string.IsNullOrWhiteSpace(model.Mobile) ||
                string.IsNullOrWhiteSpace(model.ClassName) ||
                string.IsNullOrWhiteSpace(model.Session))
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Student name, mobile number, class and session are required.";
                return RedirectToAction(nameof(EnquiryCRM));
            }

            bool isNewEnquiry = model.EnquiryId <= 0;
            var result = await _enquiryService.SaveEnquiryAsync(model, tenantId, schoolId, actionUserId);

            TempData["Result"] = result > 0 ? "1" : "0";
            TempData["Message"] = result > 0
                ? (isNewEnquiry ? "New enquiry added successfully." : "Enquiry updated successfully.")
                : "Unable to save enquiry. Please try again.";

            // Adding an enquiry is lead capture only — registration is a deliberate,
            // separate step (per-card Register action, or the Register Walk-in form on
            // the Registrations page). We do NOT auto-open registration here.
            return RedirectToAction(nameof(EnquiryCRM));
        }

        // ── POST: /ERP/Enquiry/LogFollowup (AJAX) ──────────────
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> LogFollowup([FromBody] LogFollowupRequest req)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            // Block action-driven statuses from the follow-up "also update status" path too.
            if (IsActionDrivenStatus(req.NewStatus))
                return Json(new { success = false, message = "Use the Register or Convert action to set this status." });

            // The lead's CURRENT status can lock it as well. Only the status change is
            // refused — logging the follow-up itself stays allowed, because calling an
            // admitted parent is normal.
            if (!string.IsNullOrWhiteSpace(req.NewStatus) &&
                await IsLeadStatusLockedAsync(req.EnquiryId, tenantId, schoolId, actionUserId))
                return Json(new { success = false, message = LockedStatusMessage });

            // Require lost reason when marking as Not Interested
            if (req.NewStatus is "Not Interested" or "Dropped" && string.IsNullOrWhiteSpace(req.LostReason))
                return Json(new { success = false, message = "Please provide a reason for marking Not Interested." });

            DateOnly? nextDate = null;
            if (!string.IsNullOrWhiteSpace(req.NextFollowupDate) &&
                DateOnly.TryParse(req.NextFollowupDate, out var parsed))
                nextDate = parsed;

            var result = await _enquiryService.LogFollowupAsync(
                req.EnquiryId,
                req.FollowupType ?? "Call",
                req.Outcome,
                req.Notes,
                nextDate,
                NullIfEmpty(req.NewStatus),
                NullIfEmpty(req.LostReason),
                tenantId, schoolId, actionUserId);

            return Json(new
            {
                success = result > 0,
                message = result > 0 ? "Follow-up logged." : "Unable to save follow-up."
            });
        }

        // ── POST: /ERP/Enquiry/UpdateStatus (AJAX) ─────────────
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> UpdateStatus([FromBody] UpdateStatusRequest req)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            if (req == null || req.EnquiryId <= 0 || string.IsNullOrWhiteSpace(req.Status))
                return Json(new { success = false, message = "Invalid request." });

            // Action-driven statuses cannot be set directly — they require their side-effects
            // (registration number / student record). Use the Register / Convert actions.
            if (IsActionDrivenStatus(req.Status))
                return Json(new { success = false, message = "Use the Register or Convert action to set this status." });

            // Already registered / admitted leads cannot be moved back from here either.
            if (await IsLeadStatusLockedAsync(req.EnquiryId, tenantId, schoolId, actionUserId))
                return Json(new { success = false, message = LockedStatusMessage });

            if (req.Status is "Not Interested" or "Dropped" && string.IsNullOrWhiteSpace(req.LostReason))
                return Json(new { success = false, message = "Please select a reason for Not Interested." });

            var (success, message) = await _enquiryService.UpdateStatusAsync(
                req.EnquiryId, req.Status, NullIfEmpty(req.LostReason),
                tenantId, schoolId, actionUserId);

            return Json(new { success = success > 0, message });
        }

        // ── POST: /ERP/Enquiry/RegisterEnquiry (AJAX) ──────────
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> RegisterEnquiry([FromBody] RegisterEnquiryRequest req)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            // Registration must be enabled for this school.
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, actionUserId);
            if (!workflow.EnableRegistration)
                return Json(new { success = false, message = "Registration is not enabled for this school." });

            var (ok, message, regNo, receiptNo) = await RegisterCoreAsync(
                req.EnquiryId, req.RegistrationNumber, req.RegistrationDate,
                req.RegistrationFeePaid, req.PaymentMode, req.PaymentReference,
                req.DiscountType, req.DiscountValue, req.DiscountReason,
                workflow, tenantId, schoolId, actionUserId);

            return Json(new { success = ok, message, registrationNumber = regNo, receiptNo });
        }

        // ── POST: /ERP/Enquiry/RegisterWalkin (AJAX) ───────────
        // A parent who comes ONLY to register (admission is a separate, later visit):
        // create the intake (enquiry) record AND register it in one submit. The
        // enquiry is invisible plumbing so the user never does a separate enquiry step.
        [HttpPost]
        [HasPermission("registration.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> RegisterWalkin([FromBody] RegisterWalkinRequest req)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            if (req == null)
                return Json(new { success = false, message = "Invalid request." });

            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, actionUserId);
            if (!workflow.EnableRegistration)
                return Json(new { success = false, message = "Registration is not enabled for this school." });

            // Primary mobile falls back to father's mobile (mirrors SaveEnquiry).
            var mobile = NullIfEmpty(req.Mobile) ?? NullIfEmpty(req.FatherMobile);
            if (string.IsNullOrWhiteSpace(req.StudentName) || string.IsNullOrWhiteSpace(mobile) ||
                string.IsNullOrWhiteSpace(req.ClassName) || string.IsNullOrWhiteSpace(req.Session))
                return Json(new { success = false, message = "Student name, mobile, class and session are required." });

            // 1) Create the intake record behind the scenes.
            var enquiry = new EnquiryModel
            {
                StudentName  = req.StudentName!.Trim(),
                Gender       = NullIfEmpty(req.Gender),
                ClassName    = req.ClassName!,
                Session      = req.Session!,
                FatherName   = NullIfEmpty(req.FatherName),
                FatherMobile = NullIfEmpty(req.FatherMobile),
                MotherName   = NullIfEmpty(req.MotherName),
                Mobile       = mobile!,
                ParentEmail  = NullIfEmpty(req.ParentEmail),
                LeadSource   = "Walk-in",
                Status       = "New"
            };
            var newId = await _enquiryService.SaveEnquiryAsync(enquiry, tenantId, schoolId, actionUserId);
            if (newId <= 0)
                return Json(new { success = false, message = "Could not create the registration record." });

            // 2) Register it in the same step (admission stays a later action).
            var (ok, message, regNo, receiptNo) = await RegisterCoreAsync(
                newId, req.RegistrationNumber, req.RegistrationDate,
                req.RegistrationFeePaid, req.PaymentMode, req.PaymentReference,
                req.DiscountType, req.DiscountValue, req.DiscountReason,
                workflow, tenantId, schoolId, actionUserId);

            return Json(new
            {
                success = ok,
                message = ok ? "Walk-in registered successfully." : message,
                registrationNumber = regNo,
                receiptNo,
                enquiryId = newId
            });
        }

        // Shared registration core: issue the number + (optionally) record the fee
        // receipt. Used by the per-enquiry Register action AND the walk-in 1-step form.
        private async Task<(bool ok, string message, string? regNo, string? receiptNo)> RegisterCoreAsync(
            int enquiryId, string? registrationNumber, string? registrationDate,
            bool registrationFeePaid, string? paymentMode, string? paymentReference,
            string? discountType, decimal discountValue, string? discountReason,
            AdmissionWorkflowModel workflow, int tenantId, int schoolId, int actionUserId)
        {
            // Manual number is required only when auto-generate is off.
            if (!workflow.AutoGenerateRegistrationNumber && string.IsNullOrWhiteSpace(registrationNumber))
                return (false, "Please enter a registration number.", null, null);

            // A discount needs a reason (audit) — checked before any mutation.
            if (registrationFeePaid && discountValue > 0 && string.IsNullOrWhiteSpace(discountReason))
                return (false, "Please provide a reason for the registration discount.", null, null);

            DateOnly? regDate = null;
            if (!string.IsNullOrWhiteSpace(registrationDate) &&
                DateOnly.TryParse(registrationDate, out var parsed))
                regDate = parsed;

            var (success, message, regNo) = await _enquiryService.RegisterEnquiryAsync(
                enquiryId,
                NullIfEmpty(registrationNumber),
                regDate,
                registrationFeePaid,
                workflow.AutoGenerateRegistrationNumber,
                workflow.RegistrationNumberPrefix,
                tenantId, schoolId, actionUserId);

            // When the registration fee was collected, record a real payment + receipt.
            // The amount is master data — the sum of Registration-point Fee Heads for the
            // enquiry's class — never trusted from the client.
            string? receiptNo = null;
            if (success > 0 && registrationFeePaid && workflow.EnableRegistration && workflow.EnableRegistrationFee)
            {
                var enquiry = await _enquiryService.GetEnquiryByIdAsync(enquiryId, tenantId, schoolId, actionUserId);
                if (enquiry != null)
                {
                    decimal regFee = await _schoolSettingsService.GetCollectionPointResolvedTotalAsync(
                        enquiry.ClassName ?? string.Empty, enquiry.Session ?? string.Empty,
                        "Registration", tenantId, schoolId, actionUserId);

                    if (regFee > 0)
                    {
                        // Discount amount is computed HERE from the chosen type + value —
                        // the client only picks type/value/reason, never the amount. Capped
                        // at the fee (a 100% / over-value discount = full waiver, net 0).
                        decimal discountAmount = 0m;
                        string? discType = null;
                        if (discountValue > 0 && !string.IsNullOrWhiteSpace(discountType))
                        {
                            discType = string.Equals(discountType, "Percentage", StringComparison.OrdinalIgnoreCase)
                                ? "Percentage" : "Fixed";
                            discountAmount = discType == "Percentage"
                                ? Math.Round(regFee * discountValue / 100m, 2)
                                : discountValue;
                            if (discountAmount > regFee) discountAmount = regFee;
                            if (discountAmount < 0) discountAmount = 0m;
                        }

                        decimal net = regFee - discountAmount;

                        var (paid, _, rcp) = await _feePaymentService.RecordRegistrationPaymentAsync(
                            enquiryId, net,
                            NullIfEmpty(paymentMode) ?? "Cash",
                            NullIfEmpty(paymentReference),
                            "Registration fee",
                            enquiry.Session,
                            tenantId, schoolId, actionUserId,
                            discountAmount, discType, NullIfEmpty(discountReason));

                        if (paid) receiptNo = rcp;
                    }
                }
            }

            return (success > 0, message, regNo, receiptNo);
        }

        // ── GET: /ERP/Enquiry/GetRegistrationFee (AJAX) ────────
        // Registration fee for a class/year = sum of Registration-point Fee Heads
        // configured in the fee structure. Drives the register modal's amount label.
        [HttpGet]
        public async Task<IActionResult> GetRegistrationFee(string className, string academicYear)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false, amount = 0m });

            decimal amount = await _schoolSettingsService.GetCollectionPointResolvedTotalAsync(
                className, academicYear, "Registration", TenantId(), SchoolId(), UserId());

            return Json(new { success = true, amount });
        }

        // ── POST: /ERP/Enquiry/DeleteEnquiry (AJAX) ─────────────
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteEnquiry([FromBody] DeleteEnquiryRequest req)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

            var result = await _enquiryService.DeleteEnquiryAsync(req.EnquiryId, tenantId, schoolId, actionUserId);
            return Json(new { success = result > 0, message = result > 0 ? "Enquiry deleted." : "Unable to delete." });
        }

        // ── Helpers ──────────────────────────────────────────────
        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId() => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        // A Postgres `timestamptz` comes back as UTC, so printing it straight showed
        // times 5:30 behind — a call logged at 10:54 PM read as 5:24 PM. Every screen
        // here is read in India, same as the wa.me/91 links and the en-IN money format.
        private static readonly TimeZoneInfo IndiaTime = TimeZoneInfo.FindSystemTimeZoneById("Asia/Kolkata");

        // SpecifyKind, not ToUniversalTime: the DataSet round-trip drops DateTimeKind, so
        // the UTC value arrives tagged Unspecified. ToUniversalTime() would read that as
        // local and subtract 5:30 first, which cancels the conversion out entirely.
        private static string IstText(DateTime dbUtc) =>
            TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(dbUtc, DateTimeKind.Utc), IndiaTime)
                        .ToString("dd MMM yyyy, h:mm tt");

        // Statuses that may only be set by their owning action (Register / admission save),
        // never by a direct status change — they carry required data/side-effects.
        private static bool IsActionDrivenStatus(string? status) =>
            status is "Registration Done" or "Admission Confirmed";

        // Two rows written by the same proc call count as one event. Generous on
        // purpose — a slow transaction must not split one action into two entries.
        private const int SameTransactionSeconds = 5;

        private const string LockedStatusMessage =
            "This enquiry is already registered or admitted. Use Cancel Registration or the admission screen to change its status.";

        // A lead that already reached an action-driven status is locked: its registration
        // number / student record hang off that status, so moving it back from a plain
        // status change would leave them orphaned. The UI hides the control; this is the
        // matching server-side check, since the UI is not a security boundary.
        private async Task<bool> IsLeadStatusLockedAsync(int enquiryId, int tenantId, int schoolId, int actionUserId)
        {
            var lead = await _enquiryService.GetEnquiryByIdAsync(enquiryId, tenantId, schoolId, actionUserId);
            return lead != null && IsActionDrivenStatus(lead.Status);
        }

    }
}
