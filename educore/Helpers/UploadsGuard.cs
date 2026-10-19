using EduCoreDataAccessLayer.Helpers;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;

namespace educore.Helpers
{
    /// <summary>
    /// Uploaded files (student photos, the school's logo, seal and signature) open only
    /// for someone signed in to THAT school.
    ///
    /// They are served as static files, which runs before sign-in is read, so anyone
    /// with a link could open them -- a child's photo, or the principal's signature
    /// and seal (the two things that make a certificate look real). Every upload sits
    /// under /uploads/{kind}/{tenant}/{school}/..., so the check is: signed in, and the
    /// tenant and school in the path are the user's own. The Super Admin (tenant 1) can
    /// open any school's. Anything else gets a plain 404, as if the file did not exist.
    /// </summary>
    public static class UploadsGuard
    {
        public static IApplicationBuilder UseUploadsGuard(this IApplicationBuilder app)
        {
            return app.Use(async (context, next) =>
            {
                var path = context.Request.Path.Value ?? "";
                if (!path.StartsWith(UploadPaths.RequestPath + "/", StringComparison.OrdinalIgnoreCase))
                {
                    await next();
                    return;
                }

                var auth = await context.AuthenticateAsync(CookieAuthenticationDefaults.AuthenticationScheme);
                var user = auth.Succeeded ? auth.Principal : null;
                var tenant = user?.FindFirst(Common.SK_TenantId)?.Value;
                var school = user?.FindFirst(Common.SK_SchoolId)?.Value;

                // "", "uploads", kind, tenant, school, file...
                var parts = path.Split('/');
                bool allowed = user != null
                    && (tenant == "1"
                        || (parts.Length >= 6 && parts[3] == tenant && parts[4] == school));

                if (!allowed)
                {
                    context.Response.StatusCode = StatusCodes.Status404NotFound;
                    return;
                }
                // a private file: the browser may keep it, a shared cache may not
                context.Response.Headers.CacheControl = "private, max-age=3600";
                await next();
            });
        }
    }
}
