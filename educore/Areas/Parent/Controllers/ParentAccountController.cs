using System.Security.Claims;
using System.Security.Cryptography;
using educore.Helpers;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace educore.Areas.Parent.Controllers
{
    /// <summary>
    /// Parent sign-in: mobile number -> 6-digit code -> the parent pages.
    ///
    /// The reply after "Send code" is the same whether or not the number is on a
    /// student record (PT-02). Config ParentLogin:StaticOtp: when set, that code works
    /// for every linked mobile and nothing is sent (until an SMS provider is wired);
    /// when empty, a random code is sent by SMS / WhatsApp. 5 wrong codes lock the
    /// mobile for 15 minutes (core.sp_parent_login_code), and both forms share the
    /// "otp" rate limiter with Forgot Password (Program.cs).
    /// </summary>
    [Area("Parent")]
    [AllowAnonymous]
    public class ParentAccountController : Controller
    {
        private const string PendingMobileKey = "ParentLoginMobile";

        private readonly IParentService _parents;
        private readonly INotificationService _notifications;
        private readonly IConfiguration _config;
        private readonly ILogger<ParentAccountController> _logger;

        public ParentAccountController(IParentService parents, INotificationService notifications,
                                       IConfiguration config, ILogger<ParentAccountController> logger)
        {
            _parents = parents;
            _notifications = notifications;
            _config = config;
            _logger = logger;
        }

        [HttpGet("parent/login")]
        public async Task<IActionResult> Login(int? wait = null)
        {
            // Already signed in as a parent: straight to the children.
            var auth = await HttpContext.AuthenticateAsync(ParentAuth.Scheme);
            if (auth.Succeeded && wait == null)
                return RedirectToAction("Home", "Parent");

            SetWaitMessage(wait);
            return View();
        }

        [HttpPost("parent/login")]
        [ValidateAntiForgeryToken]
        [EnableRateLimiting("otp")]
        public async Task<IActionResult> Login(string? mobile)
        {
            string clean = ParentAuth.CleanMobile(mobile);
            if (clean.Length != 10)
            {
                ViewData["Error"] = "Enter the 10-digit mobile number saved on your child's school record.";
                ViewData["Mobile"] = mobile;
                return View();
            }

            string staticCode = (_config["ParentLogin:StaticOtp"] ?? string.Empty).Trim();
            string code = staticCode.Length > 0
                ? staticCode
                : RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");

            try
            {
                var r = await _parents.IssueCodeAsync(clean, ParentAuth.HashCode(clean, code));
                if (r.Status == "LOCKED")
                {
                    SetWaitMessage(r.WaitMinutes);
                    ViewData["Mobile"] = mobile;
                    return View();
                }

                // Only a number with a child behind it gets a message (it costs money);
                // the page that follows is the same either way.
                if (staticCode.Length == 0 && r.HasChildren)
                {
                    await _notifications.SendAsync(new NotificationMessage
                    {
                        ToPhone   = clean,
                        Channels  = NotificationChannels.Sms | NotificationChannels.WhatsApp,
                        PlainText = $"Your SmartSchoolWala parent login code is {code}. It expires in 10 minutes. Do not share it."
                    });
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Parent login code could not be issued.");
                ViewData["Error"] = "Something went wrong. Please try again in a minute.";
                ViewData["Mobile"] = mobile;
                return View();
            }

            HttpContext.Session.SetString(PendingMobileKey, clean);
            return RedirectToAction(nameof(Verify));
        }

        [HttpGet("parent/verify")]
        public IActionResult Verify(int? wait = null)
        {
            var mobile = HttpContext.Session.GetString(PendingMobileKey);
            if (string.IsNullOrEmpty(mobile))
                return RedirectToAction(nameof(Login), new { wait });

            SetWaitMessage(wait);
            ViewData["Masked"] = ParentAuth.Masked(mobile);
            return View();
        }

        [HttpPost("parent/verify")]
        [ValidateAntiForgeryToken]
        [EnableRateLimiting("otp")]
        public async Task<IActionResult> Verify(string? code)
        {
            var mobile = HttpContext.Session.GetString(PendingMobileKey);
            if (string.IsNullOrEmpty(mobile))
                return RedirectToAction(nameof(Login));

            ViewData["Masked"] = ParentAuth.Masked(mobile);
            string typed = (code ?? string.Empty).Trim();
            if (typed.Length != 6 || !typed.All(char.IsDigit))
            {
                ViewData["Error"] = "Enter the 6-digit code.";
                return View();
            }

            var r = await _parents.VerifyCodeAsync(mobile, ParentAuth.HashCode(mobile, typed));
            switch (r.Status)
            {
                case "OK":
                    break;
                case "LOCKED":
                    HttpContext.Session.Remove(PendingMobileKey);
                    return RedirectToAction(nameof(Login), new { wait = Math.Max(1, r.WaitMinutes) });
                case "EXPIRED":
                    HttpContext.Session.Remove(PendingMobileKey);
                    TempData["ParentMessage"] = "Your code has expired. Please ask for a new one.";
                    return RedirectToAction(nameof(Login));
                default:
                    // Also the answer for a number with no child: nothing tells which numbers exist.
                    ViewData["Error"] = "That code did not work. Check the code, or ask the school to confirm this mobile number is on your child's record.";
                    return View();
            }

            var children = await _parents.GetChildrenAsync(mobile);
            if (children.Count == 0)
            {
                HttpContext.Session.Remove(PendingMobileKey);
                TempData["ParentMessage"] = "Parent access is not available for this number right now. Please contact the school.";
                return RedirectToAction(nameof(Login));
            }

            var claims = new List<Claim>
            {
                new Claim(ClaimTypes.Name, ParentAuth.Masked(mobile)),
                new Claim(ClaimTypes.Role, ParentAuth.Role),
                new Claim(ParentAuth.MobileClaim, mobile)
            };
            await HttpContext.SignInAsync(ParentAuth.Scheme,
                new ClaimsPrincipal(new ClaimsIdentity(claims, ParentAuth.Scheme)),
                new AuthenticationProperties { IsPersistent = true, AllowRefresh = true });

            HttpContext.Session.Remove(PendingMobileKey);

            // Audit: one LOGIN row per child, so each school sees its own parents.
            foreach (var c in children)
            {
                try { await _parents.LogAsync(c.TenantId, c.SchoolId, c.StudentId, mobile, "LOGIN", null); }
                catch (Exception ex) { _logger.LogWarning(ex, "Parent login not logged for student {StudentId}", c.StudentId); }
            }

            return RedirectToAction("Home", "Parent");
        }

        [HttpPost("parent/logout")]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Logout()
        {
            await HttpContext.SignOutAsync(ParentAuth.Scheme);
            return RedirectToAction(nameof(Login));
        }

        // The "otp" limiter (Program.cs OnRejected) and the per-mobile lock both come back
        // here with the wait in minutes (BUG-044 wording).
        private void SetWaitMessage(int? wait)
        {
            if (wait is int m && m > 0 && m <= 60)
                ViewData["Error"] = $"Too many attempts, try again in {m} minute{(m == 1 ? "" : "s")}.";
        }
    }
}
