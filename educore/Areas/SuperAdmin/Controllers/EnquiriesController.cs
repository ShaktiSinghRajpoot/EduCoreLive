using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Extensions;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace educore.Areas.SuperAdmin.Controllers
{
    /// <summary>
    /// Platform > Website Enquiries: the "Book a free demo" forms sent from the public
    /// website. The Super Admin calls the school and marks each one Contacted / Demo done / Closed.
    /// </summary>
    [Area("SuperAdmin")]
    [Authorize(Roles = AppRoles.SuperAdmin)]
    public class EnquiriesController : Controller
    {
        private readonly IWebsiteEnquiryService _enquiries;

        public EnquiriesController(IWebsiteEnquiryService enquiries)
        {
            _enquiries = enquiries;
        }

        private static readonly string[] Statuses = { "New", "Contacted", "Demo done", "Closed" };

        [HttpGet("superadmin/enquiries")]
        public async Task<IActionResult> Index(string? status)
        {
            if (!Statuses.Contains(status)) status = null;
            ViewBag.Status = status;
            ViewBag.Statuses = Statuses;
            var list = await _enquiries.GetListAsync(status, User.Identity.GetTenantId(), User.Identity.GetUserId());
            return View(list);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SetStatus(int id, string status, string? note, string? filter)
        {
            var (ok, message) = await _enquiries.SetStatusAsync(id, status, note, User.Identity.GetTenantId(), User.Identity.GetUserId());
            TempData[ok ? "SuccessMessage" : "ErrorMessage"] = ok ? "Enquiry updated." : message;
            return RedirectToAction("Index", new { status = filter });
        }
    }
}
