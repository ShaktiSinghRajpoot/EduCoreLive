using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.Admin;
using EduCoreDataAccessLayer.Services.Contract.Admin;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace educore.Areas.Admin.Controllers
{
    [Area("Admin")]
    [HasPermission("transport.view")]
    public class TransportController : Controller
    {
        private readonly ITransportService _transportService;
        private readonly IBaseService _baseService;
        private readonly IAdmissionService _admissionService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly IAdmissionWorkflowService _admissionWorkflowService;

        public TransportController(
            ITransportService transportService,
            IBaseService baseService,
            IAdmissionService admissionService,
            ISchoolSettingsService schoolSettingsService,
            IAdmissionWorkflowService admissionWorkflowService)
        {
            _transportService = transportService;
            _baseService = baseService;
            _admissionService = admissionService;
            _schoolSettingsService = schoolSettingsService;
            _admissionWorkflowService = admissionWorkflowService;
        }

        // Server-side guard: a school can turn the Transport module off in Admission
        // Workflow settings. The side-menu is hidden then, but this blocks anyone who
        // reaches a Transport URL directly. Pages redirect to the settings screen
        // (where it can be re-enabled); AJAX/API calls get a clean JSON refusal.
        public override async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
        {
            var workflow = await _admissionWorkflowService.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            if (!workflow.EnableTransport)
            {
                const string msg = "Transport module is turned off for this school. Enable it in Admission Workflow settings.";
                bool isAjax = string.Equals(
                    context.HttpContext.Request.Headers["X-Requested-With"], "XMLHttpRequest",
                    StringComparison.OrdinalIgnoreCase);

                if (isAjax)
                {
                    context.Result = new JsonResult(new { success = false, message = msg });
                }
                else
                {
                    TempData["Result"] = "0";
                    TempData["Message"] = msg;
                    context.Result = RedirectToAction("WorkflowSettings", "AdmissionWorkflow", new { area = "Admin" });
                }
                return;
            }

            await next();
        }

        // ── Pages ────────────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> Routes()
        {
            ViewBag.Routes = await _transportService.GetRoutesAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Vehicles()
        {
            ViewBag.Vehicles = await _transportService.GetVehiclesAsync(TenantId(), SchoolId(), UserId());
            ViewBag.RouteOptions = await _transportService.GetRoutesAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        [HttpGet]
        public IActionResult Assign() => View();

        // ── Routes API ───────────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetStops(int routeId)
        {
            var stops = await _transportService.GetStopsAsync(routeId, TenantId(), SchoolId(), UserId());
            return Json(stops.Select(s => new { s.StopId, s.StopName, s.MonthlyFare, s.DisplayOrder }));
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveRoute([FromBody] TransportRoute route)
        {
            if (route == null || string.IsNullOrWhiteSpace(route.RouteName))
                return Json(new { success = false, message = "Route name is required." });

            var (ok, msg, routeId) = await _transportService.SaveRouteAsync(route, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg, routeId });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteRoute(int id)
        {
            var (ok, msg) = await _transportService.DeleteRouteAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ToggleRouteStatus(int id)
        {
            var (ok, msg) = await _transportService.ToggleRouteStatusAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        // ── Vehicles API ─────────────────────────────────────────
        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveVehicle([FromBody] TransportVehicle vehicle)
        {
            if (vehicle == null || string.IsNullOrWhiteSpace(vehicle.VehicleNo))
                return Json(new { success = false, message = "Vehicle number is required." });

            var (ok, msg) = await _transportService.SaveVehicleAsync(vehicle, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> DeleteVehicle(int id)
        {
            var (ok, msg) = await _transportService.DeleteVehicleAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ToggleVehicleStatus(int id)
        {
            var (ok, msg) = await _transportService.ToggleVehicleStatusAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        // ── Assignment API ───────────────────────────────────────
        [HttpGet]
        public async Task<IActionResult> GetRoutesDropdown()
        {
            var rows = await _transportService.GetRoutesDropdownAsync(TenantId(), SchoolId(), UserId());
            // group stops under each route for the cascading select
            var routes = rows.GroupBy(r => new { r.RouteId, r.RouteName })
                .Select(g => new
                {
                    routeId   = g.Key.RouteId,
                    routeName = g.Key.RouteName,
                    stops     = g.Select(s => new { stopId = s.StopId, stopName = s.StopName, fare = s.MonthlyFare })
                });
            return Json(routes);
        }

        [HttpGet]
        public async Task<IActionResult> GetAssignment(int studentId)
        {
            var a = await _transportService.GetAssignmentAsync(studentId, TenantId(), SchoolId(), UserId());
            if (a == null) return Json((object?)null);
            return Json(new
            {
                routeId   = a.RouteId,
                stopId    = a.StopId,
                fare      = a.MonthlyFare,
                routeName = a.RouteName,
                stopName  = a.StopName,
                startDate = a.StartDate?.ToString("yyyy-MM-dd")
            });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveAssignment([FromBody] AssignRequest req)
        {
            if (req == null || req.StudentId <= 0 || req.RouteId <= 0 || req.StopId <= 0)
                return Json(new { success = false, message = "Pick a student, route and stop." });

            DateOnly start = DateOnly.FromDateTime(DateTime.Today);
            if (!string.IsNullOrWhiteSpace(req.StartDate) && DateOnly.TryParse(req.StartDate, out var d)) start = d;

            int months = MonthsToYearEnd(req.Session, start);

            var (ok, msg, fare, made) = await _transportService.SaveAssignmentAsync(
                req.StudentId, req.RouteId, req.StopId, NullIfEmpty(req.Session), start, months,
                TenantId(), SchoolId(), UserId());

            return Json(new { success = ok, message = msg, monthlyFare = fare, monthsGenerated = made });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> RemoveAssignment(int studentId)
        {
            var (ok, msg) = await _transportService.RemoveAssignmentAsync(studentId, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class AssignRequest
        {
            public int     StudentId { get; set; }
            public int     RouteId   { get; set; }
            public int     StopId    { get; set; }
            public string? Session   { get; set; }
            public string? StartDate { get; set; }
        }

        // ── Student cascade (same source as Fee Collection) ──────
        [HttpGet]
        public async Task<IActionResult> GetSessions()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            return Json(items.Select(x => x.Text).ToList());
        }

        [HttpGet]
        public async Task<IActionResult> GetClasses()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class");
            return Json(items.Select(x => x.Text).ToList());
        }

        [HttpGet]
        public async Task<IActionResult> GetSections(string session, string className)
        {
            if (string.IsNullOrWhiteSpace(session) || string.IsNullOrWhiteSpace(className))
                return Json(Array.Empty<string>());

            int ayId = await ResolveAcademicYearIdAsync(session);
            if (ayId <= 0) return Json(Array.Empty<string>());

            var setup = await _schoolSettingsService.GetAcademicSetupAsync(TenantId(), SchoolId(), ayId, UserId());
            var sections = new List<string>();
            if (setup?.ClassSections != null)
            {
                var key = setup.ClassSections.Keys.FirstOrDefault(k => k.Equals(className.Trim(), StringComparison.OrdinalIgnoreCase));
                if (key != null) sections = setup.ClassSections[key];
            }
            return Json(sections);
        }

        [HttpGet]
        public async Task<IActionResult> GetStudents(string session, string className, string section)
        {
            if (string.IsNullOrWhiteSpace(className) || string.IsNullOrWhiteSpace(section))
                return Json(Array.Empty<object>());

            var (rows, _) = await _admissionService.GetStudentsAsync(
                TenantId(), SchoolId(), UserId(),
                pageNumber: 1, pageSize: 500,
                filterClass: className.Trim(), filterSection: section.Trim(),
                filterYear: NullIfEmpty(session));

            return Json(rows.Select(s => new { id = s.StudentId, admNo = s.AdmissionNo, name = s.StudentName, roll = s.RollNo }));
        }

        // ── Helpers ──────────────────────────────────────────────
        // Bill from the start month through the end of the academic year (Indian
        // April–March). Falls back to 12 months if the year can't be parsed.
        private static int MonthsToYearEnd(string? academicYear, DateOnly start)
        {
            int endYear;
            if (!string.IsNullOrWhiteSpace(academicYear) && academicYear.Length >= 4 &&
                int.TryParse(academicYear.Substring(0, 4), out var firstYear))
                endYear = firstYear + 1;
            else
                endYear = start.Month >= 4 ? start.Year + 1 : start.Year;

            var yearEnd = new DateOnly(endYear, 3, 31);
            if (yearEnd < start) return 1;
            int months = (yearEnd.Year - start.Year) * 12 + (yearEnd.Month - start.Month) + 1;
            return Math.Clamp(months, 1, 12);
        }

        private async Task<int> ResolveAcademicYearIdAsync(string session)
        {
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear");
            var ay = ayItems.FirstOrDefault(x => string.Equals(x.Text, session, StringComparison.OrdinalIgnoreCase));
            return ay != null && int.TryParse(ay.Value, out var id) ? id : 0;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
