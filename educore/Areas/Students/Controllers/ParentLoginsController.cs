using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Students.Controllers
{
    /// <summary>
    /// Students › Parent Logins (/students/parent-logins), School Admin only: by class,
    /// how many children have a parent who has logged in to the Parent App; the latest
    /// parent logins and receipt / report-card views; and the children whose parents
    /// never logged in. Data from core.parent_access_log (parent_module.sql).
    /// </summary>
    [Area("Students")]
    [HasPermission("students.view")]
    [RequiresModule(SchoolModule.ParentApp)]
    public class ParentLoginsController : Controller
    {
        private readonly IParentService _parents;

        public ParentLoginsController(IParentService parents)
        {
            _parents = parents;
        }

        [Route("students/parent-logins")]
        public async Task<IActionResult> Index()
        {
            // Parents' mobiles and activity: the School Admin's report, not every teacher's.
            if (!await HasPermissionAttribute.UserIsAdminAsync(this))
                return Forbid();

            var report = await _parents.GetLoginReportAsync(TenantId(), SchoolId(), UserId());
            return View(report);
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
