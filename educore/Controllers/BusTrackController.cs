using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace educore.Controllers
{
    /// <summary>
    /// The parent bus-tracking page: /BusTrack/{token}. There is no parent login, so
    /// the share link's token IS the access. The token resolves its own school and
    /// route inside core.sp_transport_track_public; nothing from the caller picks
    /// the school. The page shows only that route's bus number and position while a
    /// trip runs -- no driver, phone or student data.
    ///
    /// Rate-limited per IP ("bustrack" policy in Program.cs). An unknown, revoked or
    /// malformed token gets the same "not valid" answer, so nothing tells a visitor
    /// which other tokens exist.
    /// </summary>
    [AllowAnonymous]
    [EnableRateLimiting("bustrack")]
    public class BusTrackController : Controller
    {
        private readonly ITransportTrackingService _tracking;

        public BusTrackController(ITransportTrackingService tracking) => _tracking = tracking;

        [HttpGet("BusTrack/{token}")]
        public async Task<IActionResult> Index(string token)
        {
            NoCache();
            var track = await _tracking.GetPublicTrackAsync(token);
            ViewBag.Valid = track != null;
            ViewBag.RouteName = track?.RouteName ?? "";
            ViewBag.Token = track != null ? token : "";
            return View();
        }

        [HttpGet("BusTrack/{token}/data")]
        public async Task<IActionResult> Data(string token)
        {
            NoCache();
            var track = await _tracking.GetPublicTrackAsync(token);
            if (track == null) return Json(new { valid = false });

            return Json(new
            {
                valid = true,
                route = track.RouteName,
                buses = track.Buses.Select(b => new
                {
                    vehicleNo = b.VehicleNo, lat = b.Lat, lng = b.Lng,
                    ageSeconds = b.AgeSeconds, lastPointAt = b.LastPointAt
                })
            });
        }

        // The page and its data change every few seconds and carry a secret in the URL:
        // never cache them, never index them.
        private void NoCache()
        {
            Response.Headers["Cache-Control"] = "no-store";
            Response.Headers["X-Robots-Tag"] = "noindex, nofollow";
        }
    }
}
