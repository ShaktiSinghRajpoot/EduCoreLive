using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Controllers
{
    [Authorize]
    public class DashboardsController : Controller
    {
        private readonly IDashboardService _dashboardService;

        public DashboardsController(IDashboardService dashboardService)
        {
            _dashboardService = dashboardService;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");

        // The first page after sign-in. Every figure on it used to be hardcoded in
        // the view — the same ₹13,201 for every school.
        public async Task<IActionResult> Index()
        {
            var model = await _dashboardService.GetSummaryAsync(TenantId(), SchoolId(), UserId());

            // Every signed-in role lands here. Fee collections, outstanding dues and the
            // defaulters list (names + amounts) are finance data: without fees.view they
            // are removed from the model on the server, not just hidden in the page.
            if (!await HasPermissionAttribute.UserHasAsync(this, "fees.view"))
            {
                model.ShowFinance = false;
                model.TodayCollection = 0;
                model.YesterdayCollection = 0;
                model.Outstanding = 0;
                model.DueStudents = 0;
                model.Trend.Clear();
                model.Modes.Clear();
                model.Defaulters.Clear();
                model.Recent.Clear();
            }

            return View(model);
        }
    }
}
