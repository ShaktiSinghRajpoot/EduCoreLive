using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using Microsoft.AspNetCore.Mvc;
using System.Threading.Tasks;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    //[Authorize(Roles = AppRoles.SchoolAdmin)]
    public class AdmissionWorkflowController : Controller
    {
        private readonly IAdmissionWorkflowService _admissionWorkflowService;

        public AdmissionWorkflowController(IAdmissionWorkflowService admissionWorkflowService)
        {
            _admissionWorkflowService = admissionWorkflowService;
        }

        #region Workflow Settings

        [HttpGet]
        public async Task<IActionResult> WorkflowSettings()
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            var model = await _admissionWorkflowService.GetAdmissionWorkflowAsync(tenantId, schoolId, actionUserId);

            return View(model);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveWorkflowSettings(AdmissionWorkflowModel model)
        {
            int tenantId = Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
            int schoolId = Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
            int actionUserId = Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

            // Normalise dependent flags so an invalid combination can never be persisted:
            // child settings only make sense when their parent toggle is on.
            if (!model.EnableRegistration)
            {
                model.RegistrationRequiredBeforeAdmission = false;
                model.EnableRegistrationFee = false;
            }

            if (!model.EnableRegistrationFee)
            {
                model.RegistrationFeeAmount = 0m;
            }
            else if (model.RegistrationFeeAmount < 0m)
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Registration fee amount cannot be negative.";
                return RedirectToAction(nameof(WorkflowSettings));
            }

            if (!model.EnableSecurityFee)
            {
                model.SecurityFeeAmount = 0m;
            }
            else if (model.SecurityFeeAmount < 0m)
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Security deposit amount cannot be negative.";
                return RedirectToAction(nameof(WorkflowSettings));
            }

            var result = await _admissionWorkflowService.SaveAdmissionWorkflowAsync(model, tenantId, schoolId, actionUserId);

            TempData["Result"] = result > 0 ? "1" : "0";
            TempData["Message"] = result > 0
                ? "Admission workflow settings saved successfully."
                : "Unable to save admission workflow settings.";

            return RedirectToAction(nameof(WorkflowSettings));
        }

        #endregion
    }
}
