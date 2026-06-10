using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    public class EnquiryController : Controller
    {
        private readonly IEnquiryService _enquiryService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IBaseService _baseService;

        public EnquiryController(
            IEnquiryService enquiryService,
            ISchoolSettingsService schoolSettingsService,
            IBaseService baseService)
        {
            _enquiryService = enquiryService;
            _schoolSettingsService = schoolSettingsService;
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

        // ── POST: /Admin/Enquiry/SaveEnquiry ─────────────────────
        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveEnquiry(EnquiryModel model)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

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
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> LogFollowup([FromBody] LogFollowupRequest req)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            if (req == null || req.EnquiryId <= 0)
                return Json(new { success = false, message = "Invalid request." });

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
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> UpdateStatus([FromBody] UpdateStatusRequest req)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            if (req == null || req.EnquiryId <= 0 || string.IsNullOrWhiteSpace(req.Status))
                return Json(new { success = false, message = "Invalid request." });

            if (req.Status is "Not Interested" or "Dropped" && string.IsNullOrWhiteSpace(req.LostReason))
                return Json(new { success = false, message = "Please select a reason for Not Interested." });

            var (success, message) = await _enquiryService.UpdateStatusAsync(
                req.EnquiryId, req.Status, NullIfEmpty(req.LostReason),
                tenantId, schoolId, actionUserId);

            return Json(new { success = success > 0, message });
        }

        // ── POST: /Admin/Enquiry/DeleteEnquiry (AJAX) ─────────────
        [HttpPost]
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

    }
}
