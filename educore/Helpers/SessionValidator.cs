using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Infrastructure;
using EduCoreDataAccessLayer.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using System.Security.Claims;

namespace educore.Helpers
{
    /// <summary>
    /// Re-checks a sign-in cookie on every request (wired as the cookie's
    /// OnValidatePrincipal in Program.cs).
    ///
    /// Without it a cookie outlived everything it was issued for: a deactivated user,
    /// a suspended school, or a victim who reset their password (the stolen cookie kept
    /// working) all stayed signed in for 8 hours sliding -- in practice indefinitely.
    ///
    /// The cookie is rejected when:
    ///   - the user is deactivated or deleted,
    ///   - the cookie's school no longer allows sign-in (Inactive / Suspended / Closed ...),
    ///   - the password changed since the cookie was issued (the "pwd_stamp" claim no
    ///     longer matches core.users.password_changed_at).
    ///
    /// The answer is cached per user for one minute (AppCache), so this costs one small
    /// proc call per user per minute, not one per request. Call <see cref="Forget"/>
    /// after a change that must take effect at once.
    /// </summary>
    public static class SessionValidator
    {
        /// <summary>Claim holding the password stamp at sign-in ("0" = never changed).</summary>
        public const string StampClaim = "pwd_stamp";

        private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(1);

        private sealed record SessionState(bool UserOk, bool SchoolOk, string PasswordStamp);

        public static async Task ValidateAsync(CookieValidatePrincipalContext context)
        {
            var principal = context.Principal;
            if (principal?.Identity?.IsAuthenticated != true)
                return;

            int userId   = ClaimInt(principal, Common.SK_UserId);
            int tenantId = ClaimInt(principal, Common.SK_TenantId);
            int schoolId = ClaimInt(principal, Common.SK_SchoolId);
            if (userId <= 0)
                return;   // a broken cookie is handled by the tenant middleware in Program.cs

            var services = context.HttpContext.RequestServices;
            var cache = services.GetRequiredService<AppCache>();
            var login = services.GetRequiredService<ILoginService>();

            SessionState state;
            try
            {
                state = await cache.GetOrCreateAsync(Key(tenantId, schoolId, userId), async () =>
                {
                    var r = await login.SessionCheckAsync(userId, schoolId);
                    return new SessionState(r.UserOk, r.SchoolOk, r.PasswordStamp);
                }, CacheTtl);
            }
            catch (Exception ex)
            {
                // A database hiccup must not sign every user out; the next request retries.
                services.GetRequiredService<ILoggerFactory>()
                        .CreateLogger(typeof(SessionValidator))
                        .LogError(ex, "Session check failed for user {UserId}", userId);
                return;
            }

            // Cookies issued before the stamp existed carry none: "0" matches a user
            // whose password has not changed since, so nobody is signed out by the deploy.
            string cookieStamp = principal.FindFirst(StampClaim)?.Value ?? "0";

            if (state.UserOk && state.SchoolOk && state.PasswordStamp == cookieStamp)
                return;

            context.RejectPrincipal();
            await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        }

        /// <summary>Drop a user's cached answer so the next request re-checks the database.</summary>
        public static void Forget(AppCache cache, int tenantId, int schoolId, int userId) =>
            cache.Remove(Key(tenantId, schoolId, userId));

        private static string Key(int tenantId, int schoolId, int userId) =>
            AppCache.Key($"session:u{userId}", tenantId, schoolId);

        private static int ClaimInt(ClaimsPrincipal user, string type) =>
            int.TryParse(user.FindFirst(type)?.Value, out var v) ? v : 0;
    }
}
