using educore.Helpers;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models.ERP;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.ERP.Controllers
{
    /// <summary>
    /// Front Office (/ERP/FrontOffice): visitor book, phone call log and complaints.
    /// It is the reception desk's page, so it uses the reception's keys: enquiry.view
    /// to see, enquiry.manage to enter / update.
    /// </summary>
    [Area("ERP")]
    [HasPermission("enquiry.view")]
    public class FrontOfficeController : Controller
    {
        private readonly IFrontOfficeService _fo;

        public FrontOfficeController(IFrontOfficeService fo)
        {
            _fo = fo;
        }

        public async Task<IActionResult> Index()
        {
            ViewBag.CanManage = await HasPermissionAttribute.UserHasAsync(this, "enquiry.manage");
            return View();
        }

        // op = Summary | Visitors | Calls | Complaints
        [HttpGet]
        public async Task<IActionResult> List(string op, string? from, string? to, string? status)
            => Json(await _fo.ListAsync(op ?? "", Dates.Norm(from), Dates.Norm(to), status, TenantId(), SchoolId(), UserId()));

        // op = VisitorSave | VisitorOut | CallSave | CallDone | ComplaintSave | ComplaintStatus
        [HttpPost]
        [HasPermission("enquiry.manage")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Save(string op, [FromBody] FrontOfficeEntry entry)
        {
            if (entry == null) return Json(new { success = false, message = "Invalid request." });
            var (ok, msg) = await _fo.SaveAsync(op ?? "", entry, TenantId(), SchoolId(), UserId());
            return Json(new { success = ok, message = msg });
        }

        private int TenantId() => Convert.ToInt32(User.FindFirst(Common.SK_TenantId)?.Value ?? "0");
        private int SchoolId() => Convert.ToInt32(User.FindFirst(Common.SK_SchoolId)?.Value ?? "0");
        private int UserId()   => Convert.ToInt32(User.FindFirst(Common.SK_UserId)?.Value ?? "0");
    }
}
