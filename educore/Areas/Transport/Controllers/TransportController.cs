using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using educore.Helpers;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Transport.Controllers
{
    [Area("Transport")]
    [HasPermission("transport.view")]
    [RequiresModule(SchoolModule.Transport)]
    public class TransportController : Controller
    {
        private readonly ITransportService _transportService;
        private readonly IBaseService _baseService;
        private readonly IAdmissionService _admissionService;
        private readonly ISchoolSettingsService _schoolSettingsService;
        private readonly ITransportTrackingService _tracking;

        public TransportController(
            ITransportService transportService,
            IBaseService baseService,
            IAdmissionService admissionService,
            ISchoolSettingsService schoolSettingsService,
            ITransportTrackingService tracking)
        {
            _transportService = transportService;
            _tracking = tracking;
            _baseService = baseService;
            _admissionService = admissionService;
            _schoolSettingsService = schoolSettingsService;
        }

        // ── Pages ────────────────────────────────────────────────
        [HttpGet("transport/routes")]
        public async Task<IActionResult> Routes()
        {
            ViewBag.Routes = await _transportService.GetRoutesAsync(TenantId(), SchoolId(), UserId());
            // route id -> when its parent link was made (routes without a link are absent)
            ViewBag.Shares = await _tracking.GetShareLinksAsync(TenantId(), SchoolId(), UserId());
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "transport.manage");
            return View();
        }

        [HttpGet("transport/vehicles")]
        public async Task<IActionResult> Vehicles()
        {
            ViewBag.Vehicles = await _transportService.GetVehiclesAsync(TenantId(), SchoolId(), UserId());
            ViewBag.RouteOptions = await _transportService.GetRoutesAsync(TenantId(), SchoolId(), UserId());
            ViewBag.Drivers = await _transportService.GetDriversAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        [HttpGet("transport/assign")]
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

            // With a driver linked the proc copies the phone from the staff record, so
            // only a free-text phone (no driver) is checked: optional, but when given a
            // 10-digit Indian mobile (same rule as StaffModel.Mobile). "123" used to be saved.
            vehicle.DriverPhone = string.IsNullOrWhiteSpace(vehicle.DriverPhone) ? null : vehicle.DriverPhone.Trim();
            if (vehicle.DriverStaffId is not > 0 && vehicle.DriverPhone != null
                && !System.Text.RegularExpressions.Regex.IsMatch(vehicle.DriverPhone, "^[6-9][0-9]{9}$"))
                return Json(new { success = false, message = "Enter a valid 10-digit driver phone number." });

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
            var routes = rows.GroupBy(r => new { r.RouteId, r.RouteName, r.Riders, r.Seats })
                .Select(g => new
                {
                    routeId   = g.Key.RouteId,
                    routeName = g.Key.RouteName,
                    // Riders now / seats on the route's active buses (null = no limit).
                    riders    = g.Key.Riders,
                    seats     = g.Key.Seats,
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
                startDate = a.StartDate
            });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SaveAssignment([FromBody] AssignRequest req)
        {
            if (req == null || req.StudentId <= 0 || req.RouteId <= 0 || req.StopId <= 0)
                return Json(new { success = false, message = "Pick a student, route and stop." });

            var start = Dates.Norm(req.StartDate) ?? Dates.Today;

            // The proc bills from the start month to the END of the session, read
            // from the session's real end date. This used to count months here
            // from the session NAME on an April-March assumption.
            var (ok, msg, fare, made) = await _transportService.SaveAssignmentAsync(
                req.StudentId, req.RouteId, req.StopId, NullIfEmpty(req.Session), start, 12,
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

        // ── Live tracking (transport_live_tracking.sql) ──────────
        [HttpGet("transport/live")]
        public IActionResult LiveTracking() => View();

        [HttpGet]
        public async Task<IActionResult> GetLiveTrips()
        {
            var rows = await _tracking.GetLiveTripsAsync(TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success = true,
                rows = rows.Select(t => new
                {
                    tripId = t.TripId, vehicleId = t.VehicleId, vehicleNo = t.VehicleNo,
                    routeName = t.RouteName, driverName = t.DriverName,
                    startedAt = t.StartedAt, lastPointAt = t.LastPointAt, ageSeconds = t.AgeSeconds,
                    lat = t.Lat, lng = t.Lng, accuracy = t.AccuracyM, speed = t.SpeedMps, points = t.PointCount
                })
            });
        }

        [HttpGet("transport/trips")]
        public async Task<IActionResult> TripHistory()
        {
            ViewBag.Vehicles = await _transportService.GetVehiclesAsync(TenantId(), SchoolId(), UserId());
            ViewBag.Today = Dates.Today;
            ViewBag.WeekAgo = Dates.Now.AddDays(-6).ToString(Dates.Iso);
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> GetTrips(int? vehicleId, string? from, string? to)
        {
            var rows = await _tracking.GetTripHistoryAsync(vehicleId, Dates.Norm(from), Dates.Norm(to), TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success = true,
                rows = rows.Select(t => new
                {
                    tripId = t.TripId, vehicleNo = t.VehicleNo, routeName = t.RouteName, driverName = t.DriverName,
                    startedAt = t.StartedAt, endedAt = t.EndedAt, endReason = t.EndReason,
                    points = t.PointCount, running = t.IsRunning, minutes = t.DurationMin
                })
            });
        }

        [HttpGet]
        public async Task<IActionResult> GetTripPoints(int tripId)
        {
            var pts = await _tracking.GetTripPointsAsync(tripId, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                success = true,
                points = pts.Select(p => new { lat = p.Lat, lng = p.Lng, speed = p.SpeedMps, at = p.RecordedAt })
            });
        }

        // Parent share link: create or regenerate. The raw link is returned ONCE.
        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> CreateShareLink(int routeId)
        {
            var (ok, msg, token) = await _tracking.CreateShareLinkAsync(routeId, TenantId(), SchoolId(), UserId());
            string? link = ok && token != null
                ? Url.Action("Index", "BusTrack", new { area = "", token }, Request.Scheme)
                : null;
            return Json(new { success = ok, message = msg, link });
        }

        [HttpPost]
        [HasPermission("transport.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> RevokeShareLink(int routeId)
        {
            var (ok, msg) = await _tracking.RevokeShareLinkAsync(routeId, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        // ── Student cascade (same source as Fee Collection) ──────
        [HttpGet]
        public async Task<IActionResult> GetSessions()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            return Json(items.Select(x => x.Text).ToList());
        }

        [HttpGet]
        public async Task<IActionResult> GetClasses()
        {
            var items = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "Class", TenantId().ToString(), SchoolId().ToString());
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
        private async Task<int> ResolveAcademicYearIdAsync(string session)
        {
            var ayItems = await _baseService.GetSelectListAsync("config.sp_dropdown_common", "AcademicYear", TenantId().ToString(), SchoolId().ToString());
            var ay = ayItems.FirstOrDefault(x => string.Equals(x.Text, session, StringComparison.OrdinalIgnoreCase));
            return ay != null && int.TryParse(ay.Value, out var id) ? id : 0;
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
        private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }
}
