using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
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

        // ── GET: /Admin/Enquiry/EnquiryCRM ───────────────────────
        [HttpGet]
        public async Task<IActionResult> EnquiryCRM()
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            var model = await _enquiryService.GetEnquiryCrmPageAsync(tenantId, schoolId, actionUserId);

            // Dropdowns — same pattern as FeeStructure
            model.AvailableSessions = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            model.AvailableClasses = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class");

            // Counsellors — try loading; empty list is acceptable if not configured
            try { model.AvailableCounsellors = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Counsellor"); }
            catch { model.AvailableCounsellors = new List<SelectListItem>(); }

            // Admission workflow settings — drive show/hide of the Registration stage.
            model.Workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, actionUserId);

            return View("~/Areas/Admin/Views/SchoolSettings/EnquiryCRM.cshtml", model);
        }

        // ── GET: /Admin/Enquiry/GetEnquiriesData (AJAX) ──────────
        [HttpGet]
        public async Task<IActionResult> GetEnquiriesData(int page = 1, int pageSize = 10, string? search = null, string? session = null, string? priority = null, string? className = null, string? source = null, string? pipeline = null,
          int? assignedTo = null, bool overdue = false, bool today = false)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            var (rows, totalCount) = await _enquiryService.GetEnquiriesAsync(
                tenantId, schoolId, actionUserId,
                page, pageSize,
                NullIfEmpty(search), NullIfEmpty(session), NullIfEmpty(priority),
                NullIfEmpty(className), NullIfEmpty(source), NullIfEmpty(pipeline),
                assignedTo, overdue, today);

            int totalPages = totalCount > 0 ? (int)Math.Ceiling((double)totalCount / pageSize) : 1;

            return Json(new
            {
                success = true,
                page,
                pageSize,
                totalCount,
                totalPages,
                rows = rows.Select(e => new
                {
                    enquiryId = e.EnquiryId,
                    studentName = e.StudentName,
                    studentInitials = e.StudentInitials,
                    avatarColorClass = e.AvatarColorClass,
                    parentName = e.PrimaryParentDisplay,
                    fatherName = e.FatherName,
                    fatherMobile = e.FatherMobile,
                    mobile = e.Mobile,
                    className = e.ClassName,
                    session = e.Session,
                    leadSource = e.LeadSource,
                    sourceIcon = e.SourceIcon,
                    priority = e.Priority,
                    priorityBadgeClass = e.PriorityBadgeClass,
                    status = e.Status,
                    statusBadgeClass = e.StatusBadgeClass,
                    isTerminal = e.IsTerminal,
                    estimatedFeeDisplay = e.EstimatedFeeDisplay,
                    hasFee = e.EstimatedFee.HasValue,
                    followupDisplay = e.FollowupDisplay,
                    followupCssClass = e.FollowupCssClass,
                    followupIcon = e.FollowupIcon,
                    followupSubtext = e.FollowupSubtext,
                    followupCount = e.FollowupCount,
                    daysSinceLabel = e.DaysSinceLabel,
                    whatsAppUrl = e.WhatsAppUrl,
                    callUrl = e.CallUrl,
                    pipelineKey = e.PipelineKey,
                    sourceKey = e.SourceKey,
                    priorityKey = e.PriorityKey,
                    classKey = e.ClassKey,
                    sessionKey = e.SessionKey,
                    searchKey = e.SearchKey,
                    isOverdue = e.IsOverdue,
                    isToday = e.IsToday,
                    lostReason = e.LostReason
                })
            });
        }

        // ── GET: /Admin/Enquiry/GetFollowups (AJAX) ──────────────
        [HttpGet]
        public async Task<IActionResult> GetFollowups(int enquiryId)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            var followups = await _enquiryService.GetFollowupsAsync(enquiryId, tenantId, schoolId, actionUserId);
            var history = await _enquiryService.GetStatusHistoryAsync(enquiryId, tenantId, schoolId, actionUserId);

            return Json(new
            {
                success = true,
                followups = followups.Select(f => new
                {
                    followupId = f.FollowupId,
                    followupDate = f.FollowupDate.ToString("dd MMM yyyy, h:mm tt"),
                    followupType = f.FollowupType,
                    typeIcon = f.TypeIcon,
                    outcome = f.Outcome,
                    outcomeBadgeClass = f.OutcomeBadgeClass,
                    notes = f.Notes,
                    statusBefore = f.StatusBefore,
                    statusAfter = f.StatusAfter,
                    timeAgo = f.TimeAgo
                }),
                history = history.Select(h => new
                {
                    statusFrom = h.StatusFrom ?? "Created",
                    statusTo = h.StatusTo,
                    statusToBadgeClass = h.StatusToBadgeClass,
                    changeNote = h.ChangeNote,
                    changedAt = h.CreatedAt.ToString("dd MMM yyyy, h:mm tt")
                })
            });
        }

        // ── GET: /Admin/Enquiry/GetEnquiry (AJAX) — for edit prefill ──
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

        // ── POST: /Admin/Enquiry/SaveEnquiry ─────────────────────
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

            var result = await _enquiryService.SaveEnquiryAsync(model, tenantId, schoolId, actionUserId);

            TempData["Result"] = result > 0 ? "1" : "0";
            TempData["Message"] = result > 0
                ? (model.EnquiryId > 0 ? "Enquiry updated successfully." : "New enquiry added successfully.")
                : "Unable to save enquiry. Please try again.";

            return RedirectToAction(nameof(EnquiryCRM));
        }

        // ── POST: /Admin/Enquiry/LogFollowup (AJAX) ──────────────
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

        // ── POST: /Admin/Enquiry/UpdateStatus (AJAX) ─────────────
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

            if (req.Status is "Not Interested" or "Dropped" && string.IsNullOrWhiteSpace(req.LostReason))
                return Json(new { success = false, message = "Please select a reason for Not Interested." });

            var (success, message) = await _enquiryService.UpdateStatusAsync(
                req.EnquiryId, req.Status, NullIfEmpty(req.LostReason),
                tenantId, schoolId, actionUserId);

            return Json(new { success = success > 0, message });
        }

        // ── POST: /Admin/Enquiry/RegisterEnquiry (AJAX) ──────────
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

            // Manual number is required only when auto-generate is off.
            if (!workflow.AutoGenerateRegistrationNumber && string.IsNullOrWhiteSpace(req.RegistrationNumber))
                return Json(new { success = false, message = "Please enter a registration number." });

            DateOnly? regDate = null;
            if (!string.IsNullOrWhiteSpace(req.RegistrationDate) &&
                DateOnly.TryParse(req.RegistrationDate, out var parsed))
                regDate = parsed;

            var (success, message, regNo) = await _enquiryService.RegisterEnquiryAsync(
                req.EnquiryId,
                NullIfEmpty(req.RegistrationNumber),
                regDate,
                req.RegistrationFeePaid,
                workflow.AutoGenerateRegistrationNumber,
                workflow.RegistrationNumberPrefix,
                tenantId, schoolId, actionUserId);

            // When the registration fee was collected, record a real payment + receipt
            // against the enquiry. The amount is master data — the sum of Registration-
            // point Fee Heads for the enquiry's class — never trusted from the client.
            string? receiptNo = null;
            if (success > 0 && req.RegistrationFeePaid && workflow.EnableRegistration && workflow.EnableRegistrationFee)
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

            return Json(new { success = success > 0, message, registrationNumber = regNo, receiptNo });
        }

        // ── GET: /Admin/Enquiry/GetRegistrationFee (AJAX) ────────
        // Registration fee for a class/year = sum of Registration-point Fee Heads
        // configured in the fee structure. Drives the register modal's amount label.
        [HttpGet]
        public async Task<IActionResult> GetRegistrationFee(string className, string academicYear)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false, amount = 0m });

            decimal amount = await _schoolSettingsService.GetCollectionPointTotalAsync(
                className, academicYear, "Registration", TenantId(), SchoolId(), UserId());

            return Json(new { success = true, amount });
        }

        // ── POST: /Admin/Enquiry/DeleteEnquiry (AJAX) ─────────────
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

        // Statuses that may only be set by their owning action (Register / admission save),
        // never by a direct status change — they carry required data/side-effects.
        private static bool IsActionDrivenStatus(string? status) =>
            status is "Registration Done" or "Admission Confirmed";

    }
}
