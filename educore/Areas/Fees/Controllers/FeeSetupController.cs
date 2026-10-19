using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Rendering;

namespace educore.Areas.Fees.Controllers
{
    /// <summary>
    /// Fee setup: the fee heads (Fee Head Master) and each class's fee structure.
    /// Moved here out of SchoolSettingsController, unchanged.
    /// </summary>
    [Area("Fees")]
    [RequiresModule(SchoolModule.Fees)]
    public class FeeSetupController : Controller
    {
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IBaseService _baseService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;

        public FeeSetupController(ISchoolSettingsService schoolSettingsService, IBaseService baseService, IAdmissionWorkflowService admissionWorkflowService)
        {
            _schoolSettingsService = schoolSettingsService;
            _baseService = baseService;
            _admissionWorkflowService = admissionWorkflowService;
        }

        #region FeeHead
        [HasPermission("fees.view")]
        [Route("fees/heads")]
        public async Task<IActionResult> FeeHead(FeeHead query)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            // The SAME model drives the whole page: add-form fields (empty here),
            // the grid (query.Items) and the pager/filter (Page, Search, SortColumn…),
            // all bound from the query string. Server-side paging + sorting + search.
            query.Operation = "SaveFeeHead";
            await _schoolSettingsService.GetFeeHeadPageAsync(query, tenantId, schoolId, actionUserId);

            // A page past the end (old link, or the last row of a page just deleted)
            // came back empty, and the tiles -- read from the first row -- showed
            // 0 / 0 / 0 with "No fee heads". Show the first page instead.
            if (query.Items.Count == 0 && query.Page > 1)
            {
                query.Page = 1;
                await _schoolSettingsService.GetFeeHeadPageAsync(query, tenantId, schoolId, actionUserId);
            }

            // Two workflow switches silence a head without touching the head itself:
            // a Registration-point head is only collected when the school runs a
            // registration fee, and the refundable Admission head (the security
            // deposit) only when that toggle is on. Someone reading this page saw
            // "Security Deposit 5,000" with nothing to say it was never charged.
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, actionUserId);
            ViewBag.RegistrationFeeOn = workflow.EnableRegistration && workflow.EnableRegistrationFee;
            ViewBag.SecurityFeeOn     = workflow.EnableSecurityFee;

            // The fee master is changed with settings.manage; a cashier who can only view it
            // does not see the buttons the server would refuse (QA BUG-059 / BUG-065).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "settings.manage");
            return View(query);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]   // fee master: admin-level, not the cashier's fees.manage
        public async Task<IActionResult> SaveFeeHead(FeeHead model, string? returnUrl)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            if (string.IsNullOrWhiteSpace(model.FeeHeadName))
            {
                TempData["ErrorMessage"] = "Please enter fee head name.";
                return BackToFeeHead(returnUrl);
            }

            if (string.IsNullOrWhiteSpace(model.Frequency))
            {
                TempData["ErrorMessage"] = "Please select billing cycle.";
                return BackToFeeHead(returnUrl);
            }

            if (string.IsNullOrWhiteSpace(model.FeeType))
            {
                TempData["ErrorMessage"] = "Please select fee type.";
                return BackToFeeHead(returnUrl);
            }

            // The proc upserts a NEW head on its name, so creating "tuition fee"
            // while "Tuition Fee" exists silently overwrote that head's amount and
            // cycle. From this form a new head with a taken name is refused; the
            // user edits the existing head instead.
            if (model.FeeHeadId == 0)
            {
                var all = await _schoolSettingsService.GetFeeHeadAsync(tenantId, schoolId, actionUserId);
                var clash = all.FirstOrDefault(h => string.Equals((h.FeeHeadName ?? "").Trim(), model.FeeHeadName.Trim(),
                                                                  StringComparison.OrdinalIgnoreCase));
                if (clash != null)
                {
                    TempData["ErrorMessage"] = clash.IsActive
                        ? $"A fee head called \"{clash.FeeHeadName}\" already exists. Edit it instead of creating a new one."
                        : $"A fee head called \"{clash.FeeHeadName}\" already exists but is switched off. Switch it on and edit it instead.";
                    return BackToFeeHead(returnUrl);
                }
            }

            var (ok, message) = await _schoolSettingsService.SaveFeeHeadAsync(model, tenantId, schoolId, actionUserId);

            if (ok)
                TempData["SuccessMessage"] = message;
            else
                TempData["ErrorMessage"] = message;

            return BackToFeeHead(returnUrl);
        }

        // Back to the Fee Head list the user was on -- same search, cycle filter,
        // sort and page. The forms post the page's own path + query; anything that
        // is not a local URL falls back to the plain list.
        private IActionResult BackToFeeHead(string? returnUrl)
        {
            if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
                return LocalRedirect(returnUrl);
            return RedirectToAction(nameof(FeeHead));
        }
        [HttpGet]
        [HasPermission("fees.view")]
        public async Task<IActionResult> GetFeeHeadById(int id)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var model = await _schoolSettingsService.GetFeeHeadByIdAsync(id, tenantId, schoolId, actionUserId);

            if (model == null)
                return Json(new { success = false, message = "Fee head not found." });

            return Json(new { success = true, data = model });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]   // fee master: admin-level, not the cashier's fees.manage
        public async Task<IActionResult> DeleteFeeHead(int id, string? returnUrl)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var (ok, message) = await _schoolSettingsService.DeleteFeeHeadAsync(id, tenantId, schoolId, actionUserId);

            if (ok)
                TempData["SuccessMessage"] = message;
            else
                TempData["ErrorMessage"] = message;

            return BackToFeeHead(returnUrl);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]   // fee master: admin-level, not the cashier's fees.manage
        public async Task<IActionResult> ToggleFeeHeadStatus(int id, string? returnUrl)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var (ok, message) = await _schoolSettingsService.ToggleFeeHeadStatusAsync(id, tenantId, schoolId, actionUserId);

            if (ok)
                TempData["SuccessMessage"] = message;
            else
                TempData["ErrorMessage"] = message;

            return BackToFeeHead(returnUrl);
        }
        #endregion

        #region FeeStructure

        [HttpGet]
        // Copy every class's fee structure from an earlier session into this one, optionally
        // raised by a percentage (whole rupees). Classes already set up are left alone.
        [HttpPost]
        [HasPermission("settings.manage")]   // fee master: admin-level, not the cashier's fees.manage
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CopyFeeStructure(string? fromYear, string? toYear, decimal increasePercent = 0)
        {
            if (string.IsNullOrWhiteSpace(fromYear) || string.IsNullOrWhiteSpace(toYear))
                return Json(new { success = false, message = "Choose the session to copy from." });
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");
            var (ok, msg) = await _schoolSettingsService.CopyFeeStructureAsync(
                fromYear.Trim(), toYear.Trim(), increasePercent, tenantId, schoolId, actionUserId);
            return Json(new { success = ok, message = msg });
        }

        [HasPermission("fees.view")]
        [Route("fees/structure")]
        public async Task<IActionResult> FeeStructure(string? academicYear)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            // ── Academic years from DB (same source as AcademicSetup page) ──
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", tenantId.ToString(), schoolId.ToString());
            var academicYears = ayItems.Select(x => x.Text).ToList();

            // ── Classes from DB: configured via Academic Setup ───────────────
            // The session picked in the dropdown (?academicYear=...), else the first
            // one -- the list is ordered current-first. The class chips used to come
            // from the first session whatever was picked, so a structure for next
            // session was offered this session's classes.
            var chosenAy = ayItems.FirstOrDefault(x => x.Text == academicYear) ?? ayItems.FirstOrDefault();
            int firstAyId = chosenAy != null ? Convert.ToInt32(chosenAy.Value) : 0;
            var academicSetup = await _schoolSettingsService.GetAcademicSetupAsync(tenantId, schoolId, firstAyId, actionUserId);
            var availableClasses = academicSetup?.Classes ?? new List<string>();

            // ── Fee heads for the school ────────────────────────────────────
            var rawFeeHeads = await _schoolSettingsService.GetFeeHeadAsync(tenantId, schoolId, actionUserId);

            // ── Existing structures — marks which classes are already set up ─
            var existingStructures = await _schoolSettingsService.GetFeeStructureAsync(tenantId, schoolId, actionUserId);

            // Only surface structures for classes that still exist in Academic Setup.
            // A class that was renamed/removed leaves an orphaned structure behind;
            // listing it lets the user click "Edit" on a class that has no chip to
            // select, so the form submits with no class and fails with a flashing
            // "select at least one class" error. Hide those orphans from the list.
            if (availableClasses.Count > 0)
            {
                var currentClasses = new HashSet<string>(availableClasses, StringComparer.OrdinalIgnoreCase);
                existingStructures = existingStructures
                    .Where(s => currentClasses.Contains(s.ClassName))
                    .ToList();
            }

            // List in class order (rank from Classes & Sections), not by name --
            // a name sort put "Class 10" before "Class 2".
            var classRank = (academicSetup?.ClassDetails ?? new List<AcademicClassDetail>())
                .GroupBy(c => c.ClassName, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.First().DisplayOrder, StringComparer.OrdinalIgnoreCase);
            existingStructures = existingStructures
                .OrderBy(s => classRank.TryGetValue(s.ClassName ?? "", out var r) ? r : int.MaxValue)
                .ThenBy(s => s.ClassName)
                .ThenByDescending(s => s.AcademicYear)
                .ToList();

            // Current academic year string (e.g. "2026-2027")
            string currentAy = chosenAy?.Text
                ?? (Dates.Now.Month >= 4
                    ? $"{Dates.Now.Year}-{Dates.Now.Year + 1}"
                    : $"{Dates.Now.Year - 1}-{Dates.Now.Year}");

            var model = new FeeStructureModel
            {
                AcademicYear       = currentAy,
                AvailableClasses   = availableClasses,
                AcademicYears      = academicYears,
                ExistingStructures = existingStructures,
                // An inactive head must not be offered for a new structure, but it
                // is still sent (flagged): the view keeps those rows hidden and
                // shows one only when the structure being edited already has it --
                // otherwise "Update" silently dropped it from that structure.
                FeeHeads           = rawFeeHeads.Select(fh => new FeeStructureDetailModel
                {
                    FeeHeadId   = fh.FeeHeadId,
                    FeeHeadName = fh.FeeHeadName,
                    Frequency   = fh.Frequency,
                    FeeType     = fh.FeeType,
                    // FeeGroup used to be overwritten with a three-way bucket for the
                    // page's headings, which threw away the head's real group
                    // (Academic / Transport / Optional Services) and folded Quarterly
                    // and Half Yearly into "yearly" -- so the page filed them under
                    // "Collected once per year" while billing them 4x and 2x. The page
                    // groups by Frequency directly now; this keeps the real value.
                    FeeGroup    = fh.FeeGroup,
                    CollectionPoint = fh.CollectionPoint,
                    IsRefundable    = fh.IsRefundable,
                    Amount      = fh.DefaultAmount,
                    IsActive    = fh.IsActive,
                    IsSelected  = fh.IsActive && fh.FeeType == "Mandatory"
                }).ToList()
            };

            // The fee master is changed with settings.manage; a cashier who can only view it
            // does not see the buttons the server would refuse (QA BUG-059 / BUG-065).
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "settings.manage");
            return View(model);
        }

        // Called by JS edit handler — returns saved fee head amounts for a class+year
        [HttpGet]
        [HasPermission("fees.view")]
        public async Task<IActionResult> GetFeeStructureByClass(string className, string academicYear)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(academicYear))
                return Json(new { success = false, message = "Class and academic year are required." });

            var details = await _schoolSettingsService.GetFeeStructureDetailsAsync(
                className, academicYear, tenantId, schoolId, actionUserId);

            if (details == null || details.Count == 0)
                return Json(new { success = false, message = "No saved structure found for this class and year." });

            return Json(new
            {
                success = true,
                data = details.Select(d => new
                {
                    feeHeadId = d.FeeHeadId,
                    amount    = d.Amount
                })
            });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]   // fee master: admin-level, not the cashier's fees.manage
        public async Task<IActionResult> SaveFeeStructure(FeeStructureModel model)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value  ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value  ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value    ?? "0");

            if (string.IsNullOrWhiteSpace(model.AcademicYear))
            {
                TempData["ErrorMessage"] = "Please select an academic year.";
                return RedirectToAction(nameof(FeeStructure));
            }

            if (model.SelectedClasses == null || model.SelectedClasses.Count == 0)
            {
                TempData["ErrorMessage"] = "Please select at least one class.";
                return RedirectToAction(nameof(FeeStructure));
            }

            var selectedFeeHeads = model.FeeHeads?.Where(x => x.IsSelected).ToList();
            if (selectedFeeHeads == null || selectedFeeHeads.Count == 0)
            {
                TempData["ErrorMessage"] = "Please select at least one fee head.";
                return RedirectToAction(nameof(FeeStructure));
            }

            // A cleared amount box binds as 0, which saved the head as free while the
            // page shows its default amount beside it. Blank means "use the default".
            var heads = await _schoolSettingsService.GetFeeHeadAsync(tenantId, schoolId, actionUserId);
            for (int i = 0; i < model.FeeHeads!.Count; i++)
            {
                if (!model.FeeHeads[i].IsSelected) continue;
                if (!string.IsNullOrWhiteSpace(Request.Form[$"FeeHeads[{i}].Amount"])) continue;
                var head = heads.FirstOrDefault(h => h.FeeHeadId == model.FeeHeads[i].FeeHeadId);
                if (head != null) model.FeeHeads[i].Amount = head.DefaultAmount;
            }

            // The service says which classes were written and where it stopped. The
            // old message counted the classes that were *asked* for, so it read the
            // same whether every class saved or none did.
            var (ok, message) = await _schoolSettingsService.SaveFeeStructureAsync(model, tenantId, schoolId, actionUserId);

            if (ok)
                TempData["SuccessMessage"] = message;
            else
                TempData["ErrorMessage"] = message;

            // Stay on the session that was saved, so its class chips and saved rows show.
            return RedirectToAction(nameof(FeeStructure), new { academicYear = model.AcademicYear });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [HasPermission("settings.manage")]   // fee master: admin-level, not the cashier's fees.manage
        public async Task<IActionResult> DeleteFeeStructure(int id)
        {
            int tenantId     = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId     = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value   ?? "0");

            var result = await _schoolSettingsService.DeleteFeeStructureAsync(id, tenantId, schoolId, actionUserId);

            TempData[result > 0 ? "SuccessMessage" : "ErrorMessage"] =
                result > 0 ? "Fee structure deleted." : "Unable to delete fee structure.";

            return RedirectToAction(nameof(FeeStructure));
        }

        #endregion
    }
}
