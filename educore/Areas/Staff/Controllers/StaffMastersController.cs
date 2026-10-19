using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Staff.Controllers
{
    /// <summary>
    /// Departments &amp; Designations (/staff/departments). Moved here out of
    /// SchoolSettingsController, unchanged. Part of the staff directory, so it is not
    /// behind the Staff (payroll) module switch.
    /// </summary>
    [Area("Staff")]
    public class StaffMastersController : Controller
    {
        private readonly IStaffService _staffService;

        public StaffMastersController(IStaffService staffService)
        {
            _staffService = staffService;
        }

        #region StaffMasters (Departments & Designations)
        // School-editable reference masters, kept under Settings alongside Users
        // & Roles. Feed the Add/Edit Staff dropdowns; staff_type is derived per
        // designation from its department.
        [HasPermission("staff.view")]
        [Route("staff/departments")]
        public async Task<IActionResult> StaffMasters()
        {
            var masters = await _staffService.GetMastersAsync(SmTenant(), SmSchool(), SmUser());
            return View(masters);
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveDepartment([FromBody] EduCoreDataAccessLayer.Models.DepartmentMaster dept)
        {
            if (dept == null || string.IsNullOrWhiteSpace(dept.Name))
                return Json(new { success = false, message = "Department name is required." });
            var (ok, msg) = await _staffService.SaveDepartmentAsync(dept, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveDesignation([FromBody] EduCoreDataAccessLayer.Models.DesignationMaster desig)
        {
            if (desig == null || string.IsNullOrWhiteSpace(desig.Name))
                return Json(new { success = false, message = "Designation name is required." });
            var (ok, msg) = await _staffService.SaveDesignationAsync(desig, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteMaster(string kind, int id)
        {
            var (ok, msg) = await _staffService.DeleteMasterAsync(kind, id, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("staff.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ToggleMaster(string kind, int id)
        {
            var (ok, msg) = await _staffService.ToggleMasterAsync(kind, id, SmTenant(), SmSchool(), SmUser());
            return Json(new { success = ok, message = msg });
        }

        private int SmTenant() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SmSchool() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int SmUser()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        #endregion
    }
}
