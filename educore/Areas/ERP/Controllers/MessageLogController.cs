using educore.Helpers;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Message Log (/ERP/MessageLog): every WhatsApp message the school's pages tried to send to
    /// parents (absent alerts, fee reminders, notices), sent or not, with the reason when not.
    /// </summary>
    [Area("ERP")]
    [HasPermission("notices.manage")]
    public class MessageLogController : Controller
    {
        private readonly IMessageLogService _log;

        public MessageLogController(IMessageLogService log)
        {
            _log = log;
        }

        public async Task<IActionResult> Index([FromServices] SchoolMessenger messenger)
        {
            ViewBag.WhatsAppOn = await messenger.IsOnAsync(TenantId(), SchoolId());
            ViewBag.WhatsAppTest = messenger.TestMode;
            return View();
        }

        [HttpGet]
        public async Task<IActionResult> Data(string? from, string? to, string? type)
        {
            var rows = await _log.ListAsync(from, to, type, TenantId(), SchoolId(), UserId());
            var sum = await _log.SummaryAsync(from, to, type, TenantId(), SchoolId(), UserId());
            return Json(new
            {
                summary = new { sent = sum.Sent, failed = sum.Failed, test = sum.Test, noPhone = sum.NoPhone },
                rows = rows.Select(r => new
                {
                    at = r.SentAt, type = r.AlertType, name = r.ToName ?? "", phone = r.ToPhone ?? "",
                    text = r.MessageText ?? "", status = r.Status, error = r.Error ?? "", by = r.SentBy ?? ""
                })
            });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
