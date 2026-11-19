using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Students.Controllers
{
    [Area("Students")]
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

        // ── GET: /students/enquiries ───────────────────────
        // One EnquiryCrmPageModel does it all, exactly like StudentList: the bound
        // filters/sort/page arrive on the query string, the service fills Items +
        // TotalCount + KPI. Tenant/school/user come from CLAIMS only.
        [HttpGet("students/enquiries")]
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

            // A page past the end (?Page=999, or the last row of the last page was just
            // closed) showed an empty table with no pager (QA BUG-016). Go to the last
            // page instead. The proc only reports the total on a page that has rows,
            // so page 1 is asked first.
            if (query.Items.Count == 0 && query.Page > 1)
            {
                query.Page = 1;
                await _enquiryService.GetEnquiryCrmPageAsync(query, tenantId, schoolId, actionUserId);
                if (query.TotalPages > 1)
                {
                    query.Page = query.TotalPages;
                    await _enquiryService.GetEnquiryCrmPageAsync(query, tenantId, schoolId, actionUserId);
                }
            }

            // Convert to Admission needs students.manage; without it the button only led to
            // a refusal (QA BUG-066), so the rows do not show it.
            ViewData["CanAdmit"] = await HasPermissionAttribute.UserHasAsync(this, "students.manage");
            // The register dialog offers only what the server will accept: taking the fee
            // needs fees.collect, a discount needs fees.concession (MoneyPermissionRefusalAsync).
            ViewData["CanCollectFee"] = await HasPermissionAttribute.UserHasAsync(this, "fees.collect");
            ViewData["CanDiscount"]   = await HasPermissionAttribute.UserHasAsync(this, "fees.concession");
            return View(query);
        }

        // ── GET: /students/enquiry/ExportCsv ─────────────────────────
        // The Export button (QA BUG-002). Same query string as the page, so the file
        // holds exactly what the filters show -- every page of it, not just this one.
        [HttpGet]
        public async Task<IActionResult> ExportCsv(EnquiryCrmPageModel query)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            var (items, _) = await _enquiryService.GetEnquiriesAsync(
                tenantId, schoolId, actionUserId, 1, ExportMaxRows,
                query.Search, query.FilterSession, null,
                query.FilterClass, query.FilterSource, query.FilterPipeline,
                query.FilterAssignedTo, query.FilterOverdue, query.FilterToday,
                query.SortColumn, query.SortDirection);

            var sb = new System.Text.StringBuilder();
            sb.AppendLine(CsvLine("Enquiry No", "Student", "Class", "Session", "Father", "Mother", "Mobile",
                                  "Source", "Status", "Next Follow-up", "Enquiry Date", "Registration No", "Lost Reason"));
            foreach (var e in items)
                sb.AppendLine(CsvLine(e.EnquiryId.ToString(), e.StudentName, e.ClassName, e.Session,
                                      e.FatherName, e.MotherName, e.Mobile, e.LeadSource, e.Status,
                                      Dates.Show(e.NextFollowupDate, "dd-MM-yyyy"), Dates.Show(e.EnquiryDate, "dd-MM-yyyy"),
                                      e.RegistrationNumber, e.LostReason));

            // BOM first, so Excel opens the file as UTF-8 (names in Hindi stay readable).
            var bytes = System.Text.Encoding.UTF8.GetPreamble()
                        .Concat(System.Text.Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
            return File(bytes, "text/csv", $"enquiries_{Dates.Today}.csv");
        }

        // ── GET: /students/enquiry/CheckMobile (AJAX) ─────────────────
        // "Possible duplicate" while the form is still open (QA UX-05), instead of the
        // warning after saving. Uses the list's own search, which matches the mobile
        // and father's mobile. Siblings share a number, so this only warns.
        [HttpGet]
        public async Task<IActionResult> CheckMobile(string? mobile, int excludeId = 0)
        {
            if (!PhoneRules.IsMobile(mobile))
                return Json(new { success = true, matches = Array.Empty<object>() });

            var (items, _) = await _enquiryService.GetEnquiriesAsync(
                TenantId(), SchoolId(), UserId(), 1, 5, PhoneRules.Clean(mobile));

            return Json(new
            {
                success = true,
                matches = items.Where(e => e.EnquiryId != excludeId).Select(e => new
                {
                    enquiryId   = e.EnquiryId,
                    studentName = e.StudentName,
                    className   = e.ClassName,
                    session     = e.Session,
                    status      = e.Status
                })
            });
        }

        // ── POST: /students/enquiry/CloseOverdueAsLost (AJAX) ─────────
        // Bulk "Close as lost" for stale leads (QA UX-18). Takes the same filters as
        // the page with Overdue on. preview = true only counts and names them, so the
        // user confirms the exact list before anything changes. Registered leads are
        // left alone: they carry a number and maybe a fee (Cancel Registration is
        // their own action).
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CloseOverdueAsLost([FromBody] CloseOverdueRequest req)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();
            if (req == null) return Json(new { success = false, message = "Invalid request." });

            var (items, _) = await _enquiryService.GetEnquiriesAsync(
                tenantId, schoolId, actionUserId, 1, ExportMaxRows,
                NullIfEmpty(req.Search), NullIfEmpty(req.FilterSession), null,
                NullIfEmpty(req.FilterClass), NullIfEmpty(req.FilterSource), NullIfEmpty(req.FilterPipeline),
                req.FilterAssignedTo, filterOverdue: true, filterToday: false);

            var leads = items.Where(e => e.IsOverdue && !IsActionDrivenStatus(e.Status)).ToList();

            if (req.Preview)
                return Json(new
                {
                    success = true,
                    count = leads.Count,
                    names = leads.Take(8).Select(e => $"{e.StudentName} ({e.ClassName}) - {e.FollowupSubtext}")
                });

            int closed = 0;
            foreach (var e in leads)
            {
                var (ok, _) = await _enquiryService.UpdateStatusAsync(
                    e.EnquiryId, "Not Interested", LostReasonNotResponding, tenantId, schoolId, actionUserId);
                if (ok > 0) closed++;
            }
            return Json(new
            {
                success = closed > 0,
                message = closed > 0 ? $"{closed} overdue enquir{(closed == 1 ? "y" : "ies")} closed as lost (Not Responding)."
                                     : "Nothing was closed."
            });
        }

        // ── GET: /students/enquiry/GetFollowups (AJAX) ──────────────
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

        // ── GET: /students/enquiry/GetEnquiry (AJAX) — for edit prefill ──
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
                    dob              = e.Dob,
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
                    nextFollowupDate = e.NextFollowupDate,
                    transportRequired = e.TransportRequired,
                    notes            = e.Notes
                }
            });
        }

        // ── POST: /students/enquiry/SaveEnquiry ─────────────────────
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveEnquiry(EnquiryModel model)
        {
            int tenantId = TenantId();
            int schoolId = SchoolId();
            int actionUserId = UserId();

            // Edit path: correct DETAILS only — never the state-machine / registration fields.
            string? existingNext = null;
            if (model.EnquiryId > 0)
            {
                var existing = await _enquiryService.GetEnquiryByIdAsync(model.EnquiryId, tenantId, schoolId, actionUserId);
                if (existing != null)
                {
                    existingNext = Dates.Norm(existing.NextFollowupDate);
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

            // Same 10-digit rule the form applies (EC.rule.mobile); the page is not a
            // security boundary, so a crafted post with "abc" is refused here too.
            if (!PhoneRules.IsMobile(model.Mobile) ||
                (!string.IsNullOrWhiteSpace(model.MotherMobile) && !PhoneRules.IsMobile(model.MotherMobile)))
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Enter a valid 10-digit mobile number.";
                return RedirectToAction(nameof(EnquiryCRM));
            }

            // A next follow-up cannot be planned for a day that has passed (QA BUG-003).
            // Blank is fine. On edit an old date that was not touched is kept as it is.
            var nextFollowup = Dates.Norm(model.NextFollowupDate);
            if (nextFollowup != null && string.CompareOrdinal(nextFollowup, Dates.Today) < 0 && nextFollowup != existingNext)
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Next follow-up date cannot be before today.";
                return RedirectToAction(nameof(EnquiryCRM));
            }

            bool isNewEnquiry = model.EnquiryId <= 0;
            var (result, sameMobile) = await _enquiryService.SaveEnquiryAsync(model, tenantId, schoolId, actionUserId);

            TempData["Result"] = result > 0 ? "1" : "0";
            TempData["Message"] = result > 0
                ? (isNewEnquiry ? "New enquiry added successfully." : "Enquiry updated successfully.")
                : "Unable to save enquiry. Please try again.";

            // Warn, don't block: siblings legitimately share a parent's mobile.
            if (result > 0 && sameMobile > 0)
                TempData["Warning"] = $"Mobile {model.Mobile} is already on {sameMobile} other enquiry/student record(s). Check this is not a duplicate (siblings may share it).";

            // Adding an enquiry is lead capture only — registration is a deliberate,
            // separate step (per-card Register action, or the Register Walk-in form on
            // the Registrations page). We do NOT auto-open registration here.
            return RedirectToAction(nameof(EnquiryCRM));
        }

        // ── POST: /students/enquiry/LogFollowup (AJAX) ──────────────
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

            var nextDate = Dates.Norm(req.NextFollowupDate);
            if (nextDate != null && string.CompareOrdinal(nextDate, Dates.Today) < 0)
                return Json(new { success = false, message = "Next follow-up date cannot be before today." });

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

        // ── POST: /students/enquiry/UpdateStatus (AJAX) ─────────────
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

        // ── POST: /students/enquiry/RegisterEnquiry (AJAX) ──────────
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

            if (IsFutureDate(req.RegistrationDate))
                return Json(new { success = false, message = FutureRegistrationMessage });

            var refusal = await MoneyPermissionRefusalAsync(req.RegistrationFeePaid, req.DiscountValue);
            if (refusal != null) return Json(new { success = false, message = refusal });

            var (ok, message, regNo, receiptNo) = await RegisterCoreAsync(
                req.EnquiryId, req.RegistrationNumber, req.RegistrationDate,
                req.RegistrationFeePaid, req.CollectAmount, req.PaymentMode, req.PaymentReference,
                req.DiscountType, req.DiscountValue, req.DiscountReason,
                workflow, tenantId, schoolId, actionUserId);

            return Json(new { success = ok, message, registrationNumber = regNo, receiptNo });
        }

        // ── POST: /students/enquiry/RegisterWalkin (AJAX) ───────────
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

            // All checks happen before the enquiry row is created, so a refusal
            // leaves nothing behind.
            if (!PhoneRules.IsMobile(mobile))
                return Json(new { success = false, message = "Enter a valid 10-digit mobile number." });
            if (IsFutureDate(req.RegistrationDate))
                return Json(new { success = false, message = FutureRegistrationMessage });
            if (!workflow.AutoGenerateRegistrationNumber && string.IsNullOrWhiteSpace(req.RegistrationNumber))
                return Json(new { success = false, message = "Please enter a registration number." });

            // Before the enquiry row is created, so a refusal leaves nothing behind.
            var refusal = await MoneyPermissionRefusalAsync(req.RegistrationFeePaid, req.DiscountValue);
            if (refusal != null) return Json(new { success = false, message = refusal });

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
            var (newId, _) = await _enquiryService.SaveEnquiryAsync(enquiry, tenantId, schoolId, actionUserId);
            if (newId <= 0)
                return Json(new { success = false, message = "Could not create the registration record." });

            // 2) Register it in the same step (admission stays a later action).
            var (ok, message, regNo, receiptNo) = await RegisterCoreAsync(
                newId, req.RegistrationNumber, req.RegistrationDate,
                req.RegistrationFeePaid, req.CollectAmount, req.PaymentMode, req.PaymentReference,
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

        // Registering is enquiry/registration work, but taking the fee is money work:
        // check that before anything is written. Returns null when allowed.
        private async Task<string?> MoneyPermissionRefusalAsync(bool collectsFee, decimal discountValue)
        {
            if (collectsFee && !await HasPermissionAttribute.UserHasAsync(this, "fees.collect"))
                return "You do not have permission to collect fees. Register without collecting, or ask the accounts desk.";
            if (collectsFee && discountValue > 0 && !await HasPermissionAttribute.UserHasAsync(this, "fees.concession"))
                return "You do not have permission to give a discount.";
            return null;
        }

        // Shared registration core: issue the number + (optionally) record the fee
        // receipt. Used by the per-enquiry Register action AND the walk-in 1-step form.
        private async Task<(bool ok, string message, string? regNo, string? receiptNo)> RegisterCoreAsync(
            int enquiryId, string? registrationNumber, string? registrationDate,
            bool registrationFeePaid, decimal? collectAmount, string? paymentMode, string? paymentReference,
            string? discountType, decimal discountValue, string? discountReason,
            AdmissionWorkflowModel workflow, int tenantId, int schoolId, int actionUserId)
        {
            // Manual number is required only when auto-generate is off.
            if (!workflow.AutoGenerateRegistrationNumber && string.IsNullOrWhiteSpace(registrationNumber))
                return (false, "Please enter a registration number.", null, null);

            // A discount needs a reason (audit) — checked before any mutation.
            if (registrationFeePaid && discountValue > 0 && string.IsNullOrWhiteSpace(discountReason))
                return (false, "Please provide a reason for the registration discount.", null, null);

            // Work the fee out BEFORE registering, so an over-sized discount or an
            // amount above what is payable is refused while nothing has been written.
            // These used to be capped silently: a 600 collection on a 450 payable
            // quietly became 450, and a discount above the fee became a full waiver.
            // The amount is master data -- the sum of Registration-point Fee Heads for
            // the enquiry's class -- never trusted from the client.
            bool takesFee = registrationFeePaid && workflow.EnableRegistration && workflow.EnableRegistrationFee;
            EnquiryModel? enquiry = null;
            decimal regFee = 0m, discountAmount = 0m;
            string? discType = null;
            if (takesFee)
            {
                enquiry = await _enquiryService.GetEnquiryByIdAsync(enquiryId, tenantId, schoolId, actionUserId);
                if (enquiry != null)
                {
                    regFee = await _schoolSettingsService.GetCollectionPointResolvedTotalAsync(
                        enquiry.ClassName ?? string.Empty, enquiry.Session ?? string.Empty,
                        "Registration", tenantId, schoolId, actionUserId);

                    // Discount amount is computed HERE from the chosen type + value --
                    // the client only picks type/value/reason, never the amount.
                    if (regFee > 0 && discountValue > 0 && !string.IsNullOrWhiteSpace(discountType))
                    {
                        discType = string.Equals(discountType, "Percentage", StringComparison.OrdinalIgnoreCase)
                            ? "Percentage" : "Fixed";
                        discountAmount = discType == "Percentage"
                            ? Math.Round(regFee * discountValue / 100m, 2)
                            : discountValue;
                        if (discountAmount > regFee)
                            return (false, $"Discount cannot exceed the registration fee of {regFee:N2}.", null, null);
                    }

                    if (regFee > 0 && collectAmount is > 0 && collectAmount.Value > regFee - discountAmount)
                        return (false, $"Collecting {collectAmount.Value:N2} is more than the {regFee - discountAmount:N2} payable.", null, null);
                }
            }

            var regDate = Dates.Norm(registrationDate);

            var (success, message, regNo) = await _enquiryService.RegisterEnquiryAsync(
                enquiryId,
                NullIfEmpty(registrationNumber),
                regDate,
                // Never the browser's tick: that marked fees paid with no receipt.
                // The procedure ignores it too; paid follows the receipts written below.
                false,
                workflow.AutoGenerateRegistrationNumber,
                workflow.RegistrationNumberPrefix,
                tenantId, schoolId, actionUserId);

            // When the registration fee was collected, record a real payment + receipt.
            string? receiptNo = null;
            if (success > 0 && takesFee && enquiry != null)
            {
                if (regFee > 0)
                {
                    // What the parent actually hands over. The full net is the default,
                    // so a caller that does not send an amount behaves as before; a
                    // smaller figure is a part payment and leaves a balance behind.
                    decimal net  = regFee - discountAmount;
                    decimal cash = collectAmount is > 0 ? collectAmount.Value : net;

                    var (paid, payMsg, rcp, balance) = await _feePaymentService.RecordRegistrationPaymentAsync(
                        enquiryId, cash,
                        NullIfEmpty(paymentMode) ?? "Cash",
                        NullIfEmpty(paymentReference),
                        "Registration fee",
                        enquiry.Session,
                        tenantId, schoolId, actionUserId,
                        discountAmount, discType, NullIfEmpty(discountReason),
                        feeAmount: regFee);

                    if (paid)
                    {
                        receiptNo = rcp;
                        // Say what is still owed. Silence here is how a balance gets
                        // forgotten at the counter.
                        if (balance > 0)
                            message = $"{message} {payMsg}";
                    }
                    else
                    {
                        message = $"{message} Fee not recorded: {payMsg}";
                    }
                }
                else
                {
                    // Say so rather than quietly registering without the fee.
                    message = $"{message} Fee not recorded: no registration fee is set up for this class.";
                }
            }

            return (success > 0, message, regNo, receiptNo);
        }

        // ── GET: /students/enquiry/GetRegistrationFee (AJAX) ────────
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

        // ── POST: /students/enquiry/DeleteEnquiry (AJAX) ─────────────
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

            // The procedure refuses admitted enquiries and ones holding a registration
            // receipt, and says why; pass its message through.
            var (success, message) = await _enquiryService.DeleteEnquiryAsync(req.EnquiryId, tenantId, schoolId, actionUserId);
            return Json(new { success = success > 0, message });
        }

        // ── Helpers ──────────────────────────────────────────────
        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId() => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        // Export and bulk close read the whole filtered list in one call.
        private const int ExportMaxRows = 5000;
        private const string LostReasonNotResponding = "Not Responding";

        // A registration is dated the day it happens, never ahead (QA BUG-020).
        // Blank means today. Compared on the school's clock (Dates.Today).
        private const string FutureRegistrationMessage = "Registration date cannot be in the future.";
        private static bool IsFutureDate(string? date)
        {
            var d = Dates.Norm(date);
            return d != null && string.CompareOrdinal(d, Dates.Today) > 0;
        }

        // One CSV row. Every cell is quoted; a cell starting with = + - @ gets a
        // leading apostrophe so Excel does not run it as a formula.
        private static string CsvLine(params string?[] cells) =>
            string.Join(",", cells.Select(c =>
            {
                var s = c ?? "";
                if (s.Length > 0 && "=+-@".Contains(s[0])) s = "'" + s;
                return "\"" + s.Replace("\"", "\"\"") + "\"";
            }));

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
