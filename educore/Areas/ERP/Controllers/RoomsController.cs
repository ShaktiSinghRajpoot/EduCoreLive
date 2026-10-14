using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// School Setup › Rooms (/ERP/Rooms): the school's rooms, how many periods a week each
    /// is booked in the timetable, each room's week, and rooms the timetable uses that are
    /// not in the list. Seeing needs academics.view, changing academics.manage (the same
    /// keys as the Timetable, which books the rooms).
    /// </summary>
    [Area("ERP")]
    [HasPermission("academics.view")]
    public class RoomsController : Controller
    {
        private readonly IRoomService _rooms;

        public RoomsController(IRoomService rooms)
        {
            _rooms = rooms;
        }

        public async Task<IActionResult> Index()
        {
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "academics.manage");
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Data()
            => Json(new
            {
                rooms   = await _rooms.ListAsync(TenantId(), SchoolId(), UserId()),
                unknown = await _rooms.UnknownAsync(TenantId(), SchoolId(), UserId())
            });

        // Every booked period, or one room's (the page draws the week from it).
        [HttpGet]
        public async Task<IActionResult> Usage(string? room)
            => Json(await _rooms.UsageAsync(room, TenantId(), SchoolId(), UserId()));

        // Room names for the Timetable page's Room suggestions.
        [HttpGet]
        public async Task<IActionResult> Names()
            => Json((await _rooms.ListAsync(TenantId(), SchoolId(), UserId())).Select(r => r["room_name"]?.ToString()));

        [HttpPost]
        [HasPermission("academics.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save([FromBody] RoomRequest req)
        {
            if (req == null) return Json(new { success = false, message = "Invalid request." });
            var (ok, msg) = await _rooms.SaveAsync(req.Id, req.Name, req.Type, req.Capacity, req.Building, req.Notes, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        [HttpPost]
        [HasPermission("academics.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Delete(int id)
        {
            var (ok, msg) = await _rooms.DeleteAsync(id, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        public class RoomRequest
        {
            public int?    Id       { get; set; }
            public string? Name     { get; set; }
            public string? Type     { get; set; }
            public int?    Capacity { get; set; }
            public string? Building { get; set; }
            public string? Notes    { get; set; }
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
