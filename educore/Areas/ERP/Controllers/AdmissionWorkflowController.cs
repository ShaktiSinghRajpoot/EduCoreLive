using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using System.Linq;
using System.Threading.Tasks;

namespace educore.Areas.ERP.Controllers
{
    [Area("ERP")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    [HasPermission("admission_workflow.view")]
    public class AdmissionWorkflowController : Controller
    {
        private readonly IAdmissionWorkflowService _admissionWorkflowService;
        private readonly ISchoolSettingsService _schoolSettingsService;

        public AdmissionWorkflowController(
            IAdmissionWorkflowService admissionWorkflowService,
            ISchoolSettingsService schoolSettingsService)
        {
            _admissionWorkflowService = admissionWorkflowService;
            _schoolSettingsService = schoolSettingsService;
        }

        #region Workflow Settings

        [HttpGet]
        public async Task<IActionResult> WorkflowSettings()
        {
            var model = await _admissionWorkflowService.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());

            // Inline fee setup: surface the Registration / Security-deposit fee heads
            // right on this page so a school never has to open the Fee Head master and
            // reason about the "Collection Point" dimension just to set an amount.
            var (reg, sec) = await LoadSetupFeesAsync();
            ViewBag.RegistrationFees = reg;
            ViewBag.SecurityFees = sec;

            return View(model);
        }

        [HttpPost]
        [HasPermission("admission_workflow.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveWorkflowSettings(AdmissionWorkflowModel model)
        {
            int tenantId = TenantId(), schoolId = SchoolId(), actionUserId = UserId();

            // Normalise dependent flags so an invalid combination can never be persisted:
            // child settings only make sense when their parent toggle is on. Fee amounts
            // are no longer stored here — they live as Fee Heads (set inline below / in
            // School Settings → Fee Head).
            if (!model.EnableRegistration)
            {
                model.RegistrationRequiredBeforeAdmission = false;
                model.EnableRegistrationFee = false;
            }

            var result = await _admissionWorkflowService.SaveAdmissionWorkflowAsync(model, tenantId, schoolId, actionUserId);

            TempData["Result"] = result > 0 ? "1" : "0";
            TempData["Message"] = result > 0
                ? "Admission workflow settings saved successfully."
                : "Unable to save admission workflow settings.";

            return RedirectToAction(nameof(WorkflowSettings));
        }

        #endregion

        #region Inline fee setup (AJAX)

        // Create/update a Registration or Security-deposit fee head straight from the
        // workflow page. Behind the scenes it is a normal Fee Head with the correct
        // Collection Point / refundable flag preset — the school only types a name +
        // amount, never touches the Fee Head master.
        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveSetupFee([FromBody] SetupFeeRequest req)
        {
            if (req == null || req.Amount <= 0)
                return Json(new { success = false, message = "Amount must be greater than 0." });

            bool isSecurity = string.Equals(req.Kind, "Security", System.StringComparison.OrdinalIgnoreCase);

            // Exactly ONE head per kind: reuse the existing one (update, never duplicate).
            var all = await _schoolSettingsService.GetFeeHeadAsync(TenantId(), SchoolId(), UserId());
            var existing = isSecurity ? FirstSecurity(all) : FirstRegistration(all);

            var head = new FeeHead
            {
                Operation       = "SaveFeeHead",
                FeeHeadId       = existing?.FeeHeadId ?? 0,
                FeeHeadName     = string.IsNullOrWhiteSpace(req.Name)
                                    ? (existing?.FeeHeadName ?? (isSecurity ? "Security Deposit" : "Registration Fee"))
                                    : req.Name!.Trim(),
                Frequency       = "One Time",
                DefaultAmount   = req.Amount,
                FeeType         = "Mandatory",
                FeeGroup        = "Academic",
                CollectionPoint = isSecurity ? "Admission" : "Registration",
                IsRefundable    = isSecurity                    // security deposit is refundable
            };

            var result = await _schoolSettingsService.SaveFeeHeadAsync(head, TenantId(), SchoolId(), UserId());
            if (result <= 0)
                return Json(new { success = false, message = "Unable to save the amount." });

            var (reg, sec) = await LoadSetupFeesAsync();
            return Json(new { success = true, message = "Saved.", registration = reg, security = sec });
        }

        [HttpPost]
        [HasPermission("fees.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteSetupFee([FromBody] IdRequest req)
        {
            if (req == null || req.Id <= 0)
                return Json(new { success = false, message = "Invalid request." });

            await _schoolSettingsService.DeleteFeeHeadAsync(req.Id, TenantId(), SchoolId(), UserId());

            var (reg, sec) = await LoadSetupFeesAsync();
            return Json(new { success = true, registration = reg, security = sec });
        }

        // Exactly one head per kind. Registration = the Registration-point head;
        // Security = the refundable Admission-point head. (If a school created several
        // via the Fee Head master, the inline card manages the first / primary one.)
        private static FeeHead? FirstRegistration(System.Collections.Generic.List<FeeHead> all)
            => all.FirstOrDefault(h => string.Equals(h.CollectionPoint, "Registration", System.StringComparison.OrdinalIgnoreCase));
        private static FeeHead? FirstSecurity(System.Collections.Generic.List<FeeHead> all)
            => all.FirstOrDefault(h => string.Equals(h.CollectionPoint, "Admission", System.StringComparison.OrdinalIgnoreCase) && h.IsRefundable);

        private async Task<(object? reg, object? sec)> LoadSetupFeesAsync()
        {
            var all = await _schoolSettingsService.GetFeeHeadAsync(TenantId(), SchoolId(), UserId());
            object? Map(FeeHead? h) => h == null ? null : new { id = h.FeeHeadId, name = h.FeeHeadName, amount = h.DefaultAmount };
            return (Map(FirstRegistration(all)), Map(FirstSecurity(all)));
        }

        #endregion

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }

    public class SetupFeeRequest
    {
        public string? Kind      { get; set; }   // "Registration" | "Security"
        public int     FeeHeadId { get; set; }   // 0 = new, >0 = edit
        public string? Name      { get; set; }
        public decimal Amount    { get; set; }
    }

    public class IdRequest
    {
        public int Id { get; set; }
    }
}
