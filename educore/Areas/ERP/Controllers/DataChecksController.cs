using educore.Helpers;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Students › Data Checks (/ERP/DataChecks): active students of the session with
    /// a missing / duplicate roll or admission number, bad mobile, no DOB, gender,
    /// guardian, section, photo or APAAR ID, each linking to Edit Student; plus a
    /// bulk "assign roll numbers" for one section. Seeing needs students.view,
    /// numbering students.manage.
    /// </summary>
    [Area("ERP")]
    [HasPermission("students.view")]
    public class DataChecksController : Controller
    {
        private readonly IStudentDataCheckService _checks;
        private readonly IBaseService _baseService;

        public DataChecksController(IStudentDataCheckService checks, IBaseService baseService)
        {
            _checks = checks;
            _baseService = baseService;
        }

        public async Task<IActionResult> Index()
        {
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "students.manage");
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Summary()
            => Json(await _checks.GetSummaryAsync(TenantId(), SchoolId(), UserId()));

        [HttpGet]
        public async Task<IActionResult> List(string? check)
            => Json(await _checks.GetListAsync(check ?? "", TenantId(), SchoolId(), UserId()));

        // Class names for the roll-number tool.
        [HttpGet]
        public async Task<IActionResult> Classes()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
            return Json(items.Select(x => x.Text).Where(t => !string.IsNullOrWhiteSpace(t)).Distinct().ToList());
        }

        [HttpPost]
        [HasPermission("students.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> AssignRolls([FromBody] RollRequest req)
        {
            if (req == null || string.IsNullOrWhiteSpace(req.ClassName))
                return Json(new { success = false, message = "Choose a class." });
            var (ok, msg) = await _checks.AssignRollsAsync(req.ClassName.Trim(), req.Section?.Trim(), req.Mode == "all" ? "all" : "missing",
                                                           TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class RollRequest
        {
            public string? ClassName { get; set; }
            public string? Section   { get; set; }
            public string? Mode      { get; set; }   // missing | all
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
