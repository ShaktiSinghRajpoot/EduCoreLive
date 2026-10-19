using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.Transport.Controllers
{
    /// <summary>
    /// "My Bus" -- the driver's phone page (/my-bus). It starts and ends a trip
    /// and posts the phone's GPS position while the trip runs.
    ///
    /// No permission key on purpose: being the assigned driver of an active bus
    /// (staff.user_id = this user, vehicle.driver_staff_id = that staff) IS the
    /// permission, and the stored procedure checks it again on every write. It is
    /// not under TransportController because that controller requires
    /// transport.view, which a driver normally does not have.
    ///
    /// The Transport module switch is checked here rather than with
    /// [RequiresModule]: that attribute redirects to the workflow settings page,
    /// which a driver cannot open.
    /// </summary>
    [Area("Transport")]
    [Authorize(Policy = "SchoolUserOnly")]
    public class MyBusController : Controller
    {
        private readonly ITransportTrackingService _tracking;
        private readonly IAdmissionWorkflowService _workflow;

        public MyBusController(ITransportTrackingService tracking, IAdmissionWorkflowService workflow)
        {
            _tracking = tracking;
            _workflow = workflow;
        }

        [HttpGet("my-bus")]
        public async Task<IActionResult> Index()
        {
            // Transport off for this school: nothing of it is shown, the driver goes home.
            if (!await TransportOnAsync())
                return RedirectToAction("Index", "Dashboards", new { area = "" });

            ViewBag.ModuleOff = false;
            ViewBag.Buses = await _tracking.GetMyBusesAsync(TenantId(), SchoolId(), UserId());
            return View();
        }

        public class TripRequest
        {
            public int VehicleId { get; set; }
            public int TripId    { get; set; }
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> StartTrip([FromBody] TripRequest req)
        {
            if (req == null || req.VehicleId <= 0) return Json(new { success = false, message = "Pick a bus." });
            if (!await TransportOnAsync()) return Json(new { success = false, message = ModuleOffMessage });

            var (ok, msg, tripId) = await _tracking.StartTripAsync(req.VehicleId, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg, tripId });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> EndTrip([FromBody] TripRequest req)
        {
            if (req == null || req.TripId <= 0) return Json(new { success = false, message = "No trip is running." });

            // Ending is allowed even with the module switched off, so a trip is never stuck.
            var (ok, msg) = await _tracking.EndTripAsync(req.TripId, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SendPoint([FromBody] TripPointRequest req)
        {
            if (req == null || req.TripId <= 0) return Json(new { success = false, message = "No trip is running." });
            if (!await TransportOnAsync()) return Json(new { success = false, ended = true, message = ModuleOffMessage });

            var (ok, accepted, msg) = await _tracking.AddPointAsync(req, TenantId(), SchoolId(), UserId());
            // "ended" tells the page to stop sending: the trip is over (ended, gone
            // stale, or the bus was given to another driver).
            bool ended = !ok && (msg.Contains("ended", StringComparison.OrdinalIgnoreCase)
                                 || msg.Contains("not the driver", StringComparison.OrdinalIgnoreCase));
            return Json(new { success = ok, accepted, ended, message = msg });
        }

        // ── Helpers ──────────────────────────────────────────────
        private const string ModuleOffMessage = "This page is not available.";

        private async Task<bool> TransportOnAsync()
        {
            if (TenantId() <= 1 || SchoolId() <= 0) return false;
            var settings = await _workflow.GetAdmissionWorkflowAsync(TenantId(), SchoolId(), UserId());
            return settings.EnableTransport;
        }

        private int TenantId() => int.TryParse(User.FindFirst(Common.SK_TenantId)?.Value, out var v) ? v : 0;
        private int SchoolId() => int.TryParse(User.FindFirst(Common.SK_SchoolId)?.Value, out var v) ? v : 0;
        private int UserId()   => int.TryParse(User.FindFirst(Common.SK_UserId)?.Value, out var v) ? v : 0;
    }
}
