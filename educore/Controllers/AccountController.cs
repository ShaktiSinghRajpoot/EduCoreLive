using educore.Models;
using educore.Services;
using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Models;
using EduCoreDataAccessLayer.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using System.Security.Claims;

namespace educore.Controllers
{
    public class AccountController : Controller
    {
        private readonly ILoginService _loginService;
        private readonly IBaseService _baseService;

        public AccountController(ILoginService loginService, IBaseService baseService)
        {
            _loginService = loginService;
            _baseService = baseService;
        }

        [HttpGet]
        public IActionResult Login()
        {
            return View();
        }

        [HttpPost]
        [ValidateAntiForgeryToken]
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
            return roleName switch
            {
                "Super Admin"  => RedirectToAction("SchoolList",    "Schools",         new { area = "SuperAdmin" }),
                "Tenant Admin" => RedirectToAction("SchoolList",    "Schools",         new { area = "SuperAdmin" }),
                "School Admin" => RedirectToAction("BasicProfile",  "SchoolSettings",  new { area = "Admin" }),
                "Teacher"      => RedirectToAction("SchoolList",    "Schools",         new { area = "SuperAdmin" }),
                "Accountant"   => RedirectToAction("SchoolList",    "Schools",         new { area = "SuperAdmin" }),
                "Receptionist" => RedirectToAction("SchoolList",    "Schools",         new { area = "SuperAdmin" }),
                _              => RedirectToAction("Login",         "Account")
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
        new Claim("role_code", user.RoleCode ?? string.Empty),
        new Claim("role_name", user.RoleName ?? string.Empty),

        new Claim(Common.SK_TenantId, user.TenantId?.ToString() ?? "0"),
        new Claim(Common.SK_SchoolId, user.SchoolId?.ToString() ?? "0")
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