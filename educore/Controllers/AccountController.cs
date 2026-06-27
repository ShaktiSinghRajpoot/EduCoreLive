using educore.Models;
using educore.Services;
using educore.Services.Notifications;
using EduCoreDataAccessLayer.Extensions;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;

namespace educore.Controllers
{
    public class AccountController : Controller
    {
        private readonly ILoginService _loginService;
        private readonly IBaseService _baseService;
        private readonly INotificationService _notificationService;
        private readonly IPermissionService _perms;

        public AccountController(ILoginService loginService, IBaseService baseService, INotificationService notificationService, IPermissionService perms)
        {
            _loginService = loginService;
            _baseService = baseService;
            _notificationService = notificationService;
            _perms = perms;
        }

        // ── Multi-role "focus" switch ────────────────────────────────────────────
        // A user with several roles in the same school can narrow the app to ONE role
        // ("viewing as Accountant") or go back to the combined view (roleId = 0). The
        // choice lives in the session; permissions/menu read it each request.
        [HttpPost]
        [Authorize]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> SwitchRole(int roleId, string? returnUrl = null)
        {
            int tenantId = ClaimInt(Common.SK_TenantId);
            int schoolId = ClaimInt(Common.SK_SchoolId);
            int userId   = ClaimInt(Common.SK_UserId);

            if (roleId <= 0)
            {
                HttpContext.Session.Remove(Common.SK_ActiveRoleId);   // back to combined
            }
            else
            {
                var roles = await _perms.GetUserRolesListAsync(tenantId, schoolId, userId);
                if (roles.Any(r => r.RoleId == roleId))
                    HttpContext.Session.SetInt32(Common.SK_ActiveRoleId, roleId);
                // ignore a role the user doesn't hold (no-op → stays as it was)
            }

            if (!string.IsNullOrWhiteSpace(returnUrl) && Url.IsLocalUrl(returnUrl))
                return Redirect(returnUrl);

            return RedirectToAction("Index", "Dashboards", new { area = "" });
        }

        private int ClaimInt(string type) =>
            int.TryParse(User.FindFirst(type)?.Value, out var v) ? v : 0;

        [HttpGet]
        public IActionResult Login()
        {
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [EnableRateLimiting("login")]   // WHY: 5 attempts / 5 min per IP — blunts brute-force.
        public async Task<IActionResult> Login(UserViewModel model, string? returnUrl)
        {
            if (!ModelState.IsValid)
                return View(model);

            if (string.IsNullOrEmpty(model.Email) || string.IsNullOrEmpty(model.Password))
            {
                await _loginService.SaveLoginAttemptAsync(model.Email ?? string.Empty, false, "Invalid email");
                TempData["Result"] = "0";
                TempData["Message"] = "email and password are required";
                return View(model);
            }

            var user = await _loginService.GetLoginInfoAsync(model.Email);

            if (user == null || user.UserId == 0)
            {
                await _loginService.SaveLoginAttemptAsync(model.Email, false, "Invalid email");
                TempData["Result"] = "0";
                TempData["Message"] = "Invalid email or password.";
                return View(model);
            }

            if (!user.IsActive || user.IsDeleted)
            {
                await _loginService.SaveLoginAttemptAsync(model.Email, false, "Inactive or deleted account");
                TempData["Result"] = "0";
                TempData["Message"] = "Your account is not active or deleted.";
                return View(model);
            }

            bool isPasswordValid = BCrypt.Net.BCrypt.Verify(model.Password, user.PasswordHash);

            if (!isPasswordValid)
            {
                await _loginService.SaveLoginAttemptAsync(model.Email, false, "Invalid password");
                TempData["Result"] = "0";
                TempData["Message"] = "Invalid email or password.";
                return View(model);
            }

            var roles = await _loginService.GetUserRolesAsync(user.UserId);

            if (roles == null || roles.Count == 0)
            {
                await _loginService.SaveLoginAttemptAsync(model.Email, false, "Role not assigned");
                TempData["Result"] = "0";
                TempData["Message"] = "User role is not assigned.";
                return View(model);
            }

            if (roles.Count == 1)
            {
                var selectedRole = roles.First();

                user.RoleCode = selectedRole.RoleCode;
                user.RoleName = selectedRole.RoleName;
                user.TenantId = selectedRole.TenantId;
                user.SchoolId = selectedRole.SchoolId;

                if (!IsValidSaasScope(user))
                {
                    await _loginService.SaveLoginAttemptAsync(model.Email, false, "Invalid SaaS scope");
                    TempData["Result"] = "0";
                    TempData["Message"] = "User tenant or school mapping is invalid.";
                    return View(model);
                }

                bool authorized = await UserAuthorization(user, model.RememberMe);

                if (!authorized)
                {
                    await _loginService.SaveLoginAttemptAsync(model.Email, false, "Authorization failed");
                    TempData["Result"] = "0";
                    TempData["Message"] = "User authorization failed.";
                    return View(model);
                }

                await _loginService.SaveLoginAttemptAsync(model.Email, true, null);
                await _loginService.SaveUserSessionAsync(user.UserId, HttpContext);

                if (!string.IsNullOrWhiteSpace(returnUrl) && Url.IsLocalUrl(returnUrl))
                    return Redirect(returnUrl);

                return RedirectByRole(user.RoleName);
            }

            HttpContext.Session.SetInt32("PendingUserId", user.UserId);
            HttpContext.Session.SetString("PendingEmail", model.Email);
            HttpContext.Session.SetString("RememberMe", model.RememberMe.ToString());

            return RedirectToAction("ChooseRole", "Account");
        }

        [HttpGet]
        public async Task<IActionResult> ChooseRole()
        {
            var userId = HttpContext.Session.GetInt32("PendingUserId");

            if (userId == null)
                return RedirectToAction("Login");

            var roles = await _loginService.GetUserRolesAsync(userId.Value);

            if (roles == null || roles.Count == 0)
                return RedirectToAction("Login");

            if (roles.Count == 1)
                return RedirectToAction("Login");

            return View(roles);
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ContinueAs(string roleCode)
        {
            var userId = HttpContext.Session.GetInt32("PendingUserId");
            var email = HttpContext.Session.GetString("PendingEmail");

            if (userId == null || string.IsNullOrWhiteSpace(email))
                return RedirectToAction("Login");

            var roles = await _loginService.GetUserRolesAsync(userId.Value);
            var selectedRole = roles.FirstOrDefault(x => x.RoleCode == roleCode);

            if (selectedRole == null)
            {
                TempData["Result"] = "0";
                TempData["Message"] = "Invalid role selected.";
                return RedirectToAction("ChooseRole");
            }

            var user = await _loginService.GetUserInfoByUserIdAsync(userId.Value);

            if (user == null || user.UserId == 0)
                return RedirectToAction("Login");

            user.RoleCode = selectedRole.RoleCode;
            user.RoleName = selectedRole.RoleName;
            user.TenantId = selectedRole.TenantId;
            user.SchoolId = selectedRole.SchoolId;

            if (!IsValidSaasScope(user))
            {
                TempData["Result"] = "0";
                TempData["Message"] = "User tenant or school mapping is invalid.";
                return RedirectToAction("ChooseRole");
            }

            bool rememberMe = bool.TryParse(
                HttpContext.Session.GetString("RememberMe"),
                out var remember
            ) && remember;

            bool authorized = await UserAuthorization(user, rememberMe);

            if (!authorized)
            {
                TempData["Result"] = "0";
                TempData["Message"] = "User authorization failed.";
                return RedirectToAction("Login");
            }

            await _loginService.SaveLoginAttemptAsync(email, true, null);
            await _loginService.SaveUserSessionAsync(user.UserId, HttpContext);

            HttpContext.Session.Remove("PendingUserId");
            HttpContext.Session.Remove("PendingEmail");
            HttpContext.Session.Remove("RememberMe");

            return RedirectByRole(user.RoleName);
        }

        private static bool IsValidSaasScope(UserViewModel user)
        {
            return user.RoleCode switch
            {
                "SUPER_ADMIN" => user.TenantId == 1 && user.SchoolId == 0,

                "TENANT_ADMIN" => user.TenantId.HasValue &&
                                  user.TenantId.Value > 1,

                "SCHOOL_ADMIN" or "TEACHER" or "ACCOUNTANT" or "RECEPTIONIST" =>
                    user.TenantId.HasValue &&
                    user.TenantId.Value > 1 &&
                    user.SchoolId.HasValue &&
                    user.SchoolId.Value > 0,

                _ => false
            };
        }

        private IActionResult RedirectByRole(string? roleName)
        {
            // Only platform admins land on the SuperAdmin school list. Every school-
            // level user — including dynamic/custom roles whose name we can't predict —
            // lands on the Dashboard, which all authenticated users can reach. (Sending
            // them to SuperAdmin pages caused an Access Denied after login.)
            return roleName switch
            {
                "Super Admin"  => RedirectToAction("SchoolList",   "Schools",        new { area = "SuperAdmin" }),
                "Tenant Admin" => RedirectToAction("SchoolList",   "Schools",        new { area = "SuperAdmin" }),
                "School Admin" => RedirectToAction("BasicProfile", "SchoolSettings", new { area = "Admin" }),
                _              => RedirectToAction("Index",        "Dashboards",     new { area = "" })
            };
        }

        private async Task<bool> UserAuthorization(UserViewModel user, bool rememberMe)
        {
            if (!IsValidSaasScope(user))
                return false;

            var claims = new List<Claim>
    {
        new Claim(Common.SK_UserId, user.UserId.ToString()),
        new Claim(Common.SK_EmailId, user.Email ?? string.Empty),
        new Claim(Common.SK_UserName, user.FullName ?? string.Empty),

        new Claim(ClaimTypes.Role, user.RoleCode ?? string.Empty),
        new Claim(Common.SK_RoleId, user.RoleId.ToString()),
        new Claim("role_code", user.RoleCode ?? string.Empty),
        new Claim("role_name", user.RoleName ?? string.Empty),

        new Claim(Common.SK_TenantId, user.TenantId?.ToString() ?? "0"),
        new Claim(Common.SK_SchoolId, user.SchoolId?.ToString() ?? "0"),

        // Drives the forced first-login reset gate (middleware in Program.cs).
        new Claim("must_change_password", user.MustChangePassword.ToString())
    };

            var claimsIdentity = new ClaimsIdentity(
                claims,
                CookieAuthenticationDefaults.AuthenticationScheme
            );

            var authProperties = new AuthenticationProperties
            {
                IsPersistent = rememberMe,
                ExpiresUtc = rememberMe
                    ? DateTimeOffset.UtcNow.AddDays(7)
                    : DateTimeOffset.UtcNow.AddHours(8),
                AllowRefresh = true
            };

            await HttpContext.SignInAsync(
                CookieAuthenticationDefaults.AuthenticationScheme,
                new ClaimsPrincipal(claimsIdentity),
                authProperties
            );

            SaveUserDataToSession(user);

            return true;
        }
        public IActionResult AccessDenied()
        {
            return View();
        }

        public IActionResult Error()
        {
            var exceptionFeature = HttpContext.Features.Get<IExceptionHandlerPathFeature>();
            var statusCodeFeature = HttpContext.Features.Get<IStatusCodeReExecuteFeature>();

            var model = new ErrorViewModel
            {
                RequestId = HttpContext.TraceIdentifier,
                ErrorMessage = exceptionFeature?.Error?.Message
                    ?? $"HTTP Error {Response.StatusCode}",
                StackTrace = exceptionFeature?.Error?.StackTrace,
                Path = exceptionFeature?.Path
                    ?? statusCodeFeature?.OriginalPath
            };

            return View(model);
        }
        private void SaveUserDataToSession(UserViewModel user)
        {
            HttpContext.Session.SetInt32("UserId", user.UserId);
            HttpContext.Session.SetString("Email", user.Email ?? string.Empty);
            HttpContext.Session.SetString("UserName", user.FullName ?? string.Empty);
            HttpContext.Session.SetString("RoleCode", user.RoleCode ?? string.Empty);
            HttpContext.Session.SetString("RoleName", user.RoleName ?? string.Empty);
            HttpContext.Session.SetInt32("TenantId", user.TenantId ?? 0);
            HttpContext.Session.SetInt32("SchoolId", user.SchoolId ?? 0);
        }
        public IActionResult Error404()
        {
            return View();
        }

        private const string ResetUserIdKey = "ResetUserId";

        [HttpGet]
        public IActionResult ForgotPassword()
        {
            return View(new ForgotPasswordViewModel());
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [EnableRateLimiting("login")]   // WHY: share the 5/5-min IP budget — blunts OTP spam + account enumeration.
        public async Task<IActionResult> ForgotPassword(ForgotPasswordViewModel model)
        {
            if (!ModelState.IsValid)
                return View(model);

            var otp = GenerateOtp();
            var user = await _loginService.RequestPasswordOtpAsync(model.Identifier.Trim(), Sha256Hex(otp));

            // Always proceed to the verify page (never reveal whether the account exists). When the
            // identifier matched nobody we store user id 0 so any code entered just fails as invalid.
            HttpContext.Session.SetInt32(ResetUserIdKey, user?.UserId ?? 0);

            if (user != null && user.UserId > 0)
            {
                await _notificationService.SendAsync(new NotificationMessage
                {
                    ToEmail = user.Email,
                    ToPhone = user.Phone,
                    ToName = user.FullName,
                    Channels = NotificationChannels.All,
                    Subject = "Your EduCore verification code",
                    HtmlBody = BuildOtpEmail(user.FullName, otp),
                    PlainText = $"Your EduCore password reset code is {otp}. It expires in 10 minutes. Do not share it."
                });
            }

            return RedirectToAction(nameof(VerifyOtp));
        }

        [HttpGet]
        public IActionResult VerifyOtp()
        {
            if (HttpContext.Session.GetInt32(ResetUserIdKey) == null)
                return RedirectToAction(nameof(ForgotPassword));

            return View(new VerifyOtpViewModel());
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        [EnableRateLimiting("login")]
        public async Task<IActionResult> VerifyOtp(VerifyOtpViewModel model)
        {
            var userId = HttpContext.Session.GetInt32(ResetUserIdKey);
            if (userId == null)
                return RedirectToAction(nameof(ForgotPassword));

            if (!ModelState.IsValid)
                return View(model);

            var newHash = BCrypt.Net.BCrypt.HashPassword(model.NewPassword);
            var status = await _loginService.ResetWithOtpAsync(userId.Value, Sha256Hex(model.Otp.Trim()), newHash);

            switch (status)
            {
                case "OK":
                    HttpContext.Session.Remove(ResetUserIdKey);
                    TempData["Result"] = "1";
                    TempData["Message"] = "Your password has been reset. Please log in with your new password.";
                    return RedirectToAction(nameof(Login));

                case "INVALID":
                    ModelState.AddModelError(nameof(model.Otp), "Incorrect code. Please check and try again.");
                    return View(model);

                case "LOCKED":
                    HttpContext.Session.Remove(ResetUserIdKey);
                    TempData["Result"] = "0";
                    TempData["Message"] = "Too many incorrect attempts. Please request a new code.";
                    return RedirectToAction(nameof(ForgotPassword));

                default: // EXPIRED
                    HttpContext.Session.Remove(ResetUserIdKey);
                    TempData["Result"] = "0";
                    TempData["Message"] = "Your code has expired. Please request a new one.";
                    return RedirectToAction(nameof(ForgotPassword));
            }
        }

        // Cryptographically-secure 6-digit OTP. Only its SHA-256 hash is stored.
        private static string GenerateOtp() =>
            RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");

        private static string Sha256Hex(string value) =>
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

        private static string BuildOtpEmail(string? fullName, string otp)
        {
            string Enc(string s) => System.Net.WebUtility.HtmlEncode(s);
            var name = string.IsNullOrWhiteSpace(fullName) ? "there" : fullName!;
            var sb = new StringBuilder();
            sb.Append("<div style=\"font-family:Segoe UI,Arial,sans-serif;color:#2b1b12;\">");
            sb.Append($"<p>Hi {Enc(name)},</p>");
            sb.Append("<p>Use this code to reset your EduCore password:</p>");
            sb.Append($"<p style=\"font-size:30px;font-weight:800;letter-spacing:6px;color:#ff8a00;margin:16px 0;\">{Enc(otp)}</p>");
            sb.Append("<p style=\"font-size:13px;color:#9a938b;\">This code expires in 10 minutes. If you didn't request it, you can ignore this email.</p>");
            sb.Append("</div>");
            return sb.ToString();
        }

        [HttpGet]
        [Authorize]
        public IActionResult ChangePassword()
        {
            return View(new ChangePasswordViewModel { IsForced = MustChangePassword() });
        }

        [HttpPost]
        [Authorize]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> ChangePassword(ChangePasswordViewModel model)
        {
            model.IsForced = MustChangePassword();

            // Current password is only needed for a normal (self-service) change. On the
            // forced first-login reset the user already authenticated with the temp
            // password, so we skip asking for / verifying it again.
            if (!model.IsForced && string.IsNullOrWhiteSpace(model.CurrentPassword))
                ModelState.AddModelError(nameof(model.CurrentPassword), "Current password is required.");

            if (!ModelState.IsValid)
                return View(model);

            var userId = User.Identity.GetUserId();
            var user = await _loginService.GetUserInfoByUserIdAsync(userId);

            if (user == null || user.UserId == 0 || string.IsNullOrEmpty(user.PasswordHash))
            {
                // Session out of sync with the DB — start over.
                await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
                HttpContext.Session.Clear();
                return RedirectToAction("Login");
            }

            if (!model.IsForced && !BCrypt.Net.BCrypt.Verify(model.CurrentPassword, user.PasswordHash))
            {
                ModelState.AddModelError(nameof(model.CurrentPassword), "Current password is incorrect.");
                return View(model);
            }

            if (BCrypt.Net.BCrypt.Verify(model.NewPassword, user.PasswordHash))
            {
                ModelState.AddModelError(nameof(model.NewPassword), "New password must be different from the current password.");
                return View(model);
            }

            var newHash = BCrypt.Net.BCrypt.HashPassword(model.NewPassword);
            await _loginService.ChangePasswordAsync(userId, newHash);

            // Re-issue the cookie with must_change_password = false so the forced-reset
            // gate releases immediately, without forcing a re-login.
            await RefreshClaimsClearingForcedReset();

            TempData["Result"] = "1";
            TempData["Message"] = "Your password has been changed successfully.";

            return RedirectByRole(User.FindFirst("role_name")?.Value);
        }

        private bool MustChangePassword() =>
            string.Equals(User.FindFirst("must_change_password")?.Value, "True", StringComparison.OrdinalIgnoreCase);

        // Rebuilds the auth cookie from the current claims, flipping must_change_password to
        // false. Preserves the active role/tenant/school exactly (important for multi-role users).
        private async Task RefreshClaimsClearingForcedReset()
        {
            var claims = User.Claims
                .Where(c => c.Type != "must_change_password")
                .ToList();
            claims.Add(new Claim("must_change_password", bool.FalseString));

            var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);

            await HttpContext.SignInAsync(
                CookieAuthenticationDefaults.AuthenticationScheme,
                new ClaimsPrincipal(identity));
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
        public async Task<IActionResult> Logout()
        {
            await HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
            HttpContext.Session.Clear();

            return RedirectToAction("Login", "Account");
        }

    }
}