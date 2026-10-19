using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Fees.Controllers
{
    /// <summary>
    /// Fee › Fee Dashboard (/fees): where the money stands, collection by
    /// month / day / mode / staff, classes and class teachers to chase, class x fee head,
    /// families owing most and how they pay, doubtful dues, money given away and billing
    /// checks. Read-only, one call (core.sp_fee_dashboard). Same permission as Fee Reports.
    /// </summary>
    [Area("Fees")]
    [RequiresModule(SchoolModule.Fees)]
    [HasPermission("fees.view")]
    public class FeeDashboardController : Controller
    {
        private readonly IDashboardReportService _reports;

        public FeeDashboardController(IDashboardReportService reports)
        {
            _reports = reports;
        }

        [Route("fees")]
        public IActionResult Index() => View();

        [HttpGet]
        public async Task<IActionResult> Data()
        {
            var d = await _reports.GetFeeDashboardAsync(TenantId(), SchoolId(), UserId());
            return Json(new { today = Dates.Today, data = d });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
