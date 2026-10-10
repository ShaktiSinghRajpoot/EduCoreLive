using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace educore.Helpers
{
    /// <summary>
    /// Controller/action guard for the dynamic RBAC system, e.g.
    /// <c>[HasPermission("rbac.manage")]</c>. Resolves <see cref="IPermissionService"/>
    /// from DI and 403s when the signed-in user's role lacks the permission.
    /// SUPER_ADMIN / SCHOOL_ADMIN bypass (handled inside the service).
    /// </summary>
    public sealed class HasPermissionAttribute : TypeFilterAttribute
    {
        public HasPermissionAttribute(string permissionKey)
            : base(typeof(HasPermissionFilter))
        {
            Arguments = new object[] { permissionKey };
        }

        private sealed class HasPermissionFilter : IAsyncAuthorizationFilter
        {
            private readonly string _permissionKey;
            private readonly IPermissionService _perms;

            public HasPermissionFilter(string permissionKey, IPermissionService perms)
            {
                _permissionKey = permissionKey;
                _perms = perms;
            }

            public async Task OnAuthorizationAsync(AuthorizationFilterContext context)
            {
                var user = context.HttpContext.User;
                if (user?.Identity?.IsAuthenticated != true)
                {
                    context.Result = new ChallengeResult();
                    return;
                }

                int tenantId = ClaimInt(user, Common.SK_TenantId);
                int schoolId = ClaimInt(user, Common.SK_SchoolId);
                int userId   = ClaimInt(user, Common.SK_UserId);

                // Honor the multi-role "focus" choice (0/absent = combined view of all roles).
                int activeRoleId = context.HttpContext.Session.GetInt32(Common.SK_ActiveRoleId) ?? 0;

                if (!await _perms.HasPermissionAsync(tenantId, schoolId, userId, _permissionKey, activeRoleId))
                    context.Result = new StatusCodeResult(StatusCodes.Status403Forbidden);
            }

            private static int ClaimInt(System.Security.Claims.ClaimsPrincipal u, string type) =>
                int.TryParse(u.FindFirst(type)?.Value, out var v) ? v : 0;
        }

        /// <summary>
        /// The same check as the attribute, for use inside an action when only some
        /// requests need the permission -- e.g. registering is enquiry.manage, but
        /// registering AND taking the fee also needs fees.collect.
        /// </summary>
        public static async Task<bool> UserHasAsync(Controller controller, string permissionKey)
        {
            var ctx   = controller.HttpContext;
            var perms = ctx.RequestServices.GetRequiredService<IPermissionService>();
            int activeRoleId = ctx.Session.GetInt32(Common.SK_ActiveRoleId) ?? 0;
            return await perms.HasPermissionAsync(
                ClaimInt(ctx.User, Common.SK_TenantId),
                ClaimInt(ctx.User, Common.SK_SchoolId),
                ClaimInt(ctx.User, Common.SK_UserId),
                permissionKey, activeRoleId);
        }

        private static int ClaimInt(System.Security.Claims.ClaimsPrincipal u, string type) =>
            int.TryParse(u.FindFirst(type)?.Value, out var v) ? v : 0;
    }
}
