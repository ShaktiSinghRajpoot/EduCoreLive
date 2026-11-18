using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services.Contract.SuperAdmin;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace educore.Controllers
{
    /// <summary>
    /// The public website at smartschoolwala.com ("/"). A visitor sees the product
    /// page and its Login button opens the portal (/Account/Login). Someone already
    /// signed in goes straight to their dashboard, as "/" did before.
    /// The demo form posts to /enquiry; the Super Admin sees it under Website Enquiries.
    /// </summary>
    [AllowAnonymous]
    public class SiteController : Controller
    {
        // HEAD too: uptime checks and some crawlers ask with HEAD, which got a 405.
        [HttpGet("/")]
        [HttpHead("/")]
        public IActionResult Index()
        {
            if (User.Identity?.IsAuthenticated == true)
                return RedirectToAction("Index", "Dashboards", new { area = "" });

            return View();
        }

        // Pages for one search each ("school fee management software", ...). Open to everyone,
        // signed in or not: unlike "/" they are not the way into the portal.
        [HttpGet("/school-fee-management-software")]
        [HttpHead("/school-fee-management-software")]
        public IActionResult FeeManagement() => View();

        [HttpGet("/school-attendance-management-software")]
        [HttpHead("/school-attendance-management-software")]
        public IActionResult AttendanceManagement() => View();

        // Privacy policy and terms of use (QA BUG-009), linked from the footer, the demo
        // form and the login page.
        [HttpGet("/privacy")]
        [HttpHead("/privacy")]
        public IActionResult Privacy() => View();

        [HttpGet("/terms")]
        [HttpHead("/terms")]
        public IActionResult Terms() => View();

        // "Register your school": the onboarding form. It builds a WhatsApp message to the
        // support number (Support:WhatsApp); nothing is stored on the server.
        [HttpGet("/school-onboarding")]
        [HttpHead("/school-onboarding")]
        public IActionResult SchoolOnboarding() => View();

        // The demo form only POSTs here. Opening /enquiry (a refresh, a bookmark) used to
        // give a 405 error page (BUG-013); send the visitor to the form instead.
        [HttpGet("/enquiry")]
        [HttpHead("/enquiry")]
        public IActionResult EnquiryPage() => Redirect("/#contact");

        // The public pages Google should know about. Add a page here when the website gets one.
        private static readonly string[] PublicPages =
        {
            "/",
            "/school-fee-management-software",
            "/school-attendance-management-software",
            "/school-onboarding",
            "/privacy",
            "/terms"
        };

        /// <summary>sitemap.xml for search engines (robots.txt in wwwroot points here).</summary>
        [HttpGet("/sitemap.xml")]
        public IActionResult Sitemap([FromServices] Microsoft.Extensions.Options.IOptions<educore.Services.SupportSettings> support)
        {
            string siteUrl = support.Value.PublicUrl(Request);

            var xml = new System.Text.StringBuilder();
            xml.AppendLine("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
            xml.AppendLine("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">");
            foreach (var page in PublicPages)
                xml.AppendLine("  <url><loc>" + System.Security.SecurityElement.Escape(siteUrl + page) + "</loc></url>");
            xml.AppendLine("</urlset>");

            return Content(xml.ToString(), "application/xml", System.Text.Encoding.UTF8);
        }

        public sealed class EnquiryForm
        {
            public string? Name { get; set; }
            public string? Designation { get; set; }
            public string? School { get; set; }
            public string? City { get; set; }
            public string? Phone { get; set; }
            public string? Email { get; set; }
            public string? Students { get; set; }
            public string? Message { get; set; }
            public string? Website { get; set; }   // hidden field: a person leaves it empty, a bot fills it
        }

        [HttpPost("/enquiry")]
        [ValidateAntiForgeryToken]
        [EnableRateLimiting("enquiry")]
        public async Task<IActionResult> Enquiry([FromForm] EnquiryForm form, [FromServices] IWebsiteEnquiryService enquiries)
        {
            // a bot filled the hidden field: say thanks and keep nothing
            if (!string.IsNullOrWhiteSpace(form.Website))
                return Json(new { success = true, message = "Thank you. We will call you within one working day." });

            var (ok, message) = await enquiries.SaveAsync(new WebsiteEnquiry
            {
                ContactName = form.Name ?? "",
                Designation = form.Designation,
                SchoolName = form.School ?? "",
                City = form.City,
                Phone = form.Phone ?? "",
                Email = form.Email,
                Students = form.Students,
                Message = form.Message
            }, HttpContext.Connection.RemoteIpAddress?.ToString());

            return Json(new { success = ok, message });
        }
    }
}
