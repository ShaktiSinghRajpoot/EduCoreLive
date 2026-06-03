using EduCoreDataAccessLayer.Helpers;
using System.Security.Claims;
using System.Security.Principal;

namespace EduCoreDataAccessLayer.Extensions
{
    public static class IdentityExtensions
    {
        public static bool IsLoggedIn(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_UserId);
            return claim != null;
        }

        public static int GetUserId(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_UserId);
            return claim != null ? Convert.ToInt32(claim.Value) : 0;
        }

        public static int GetTenantId(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_TenantId);
            return claim != null ? Convert.ToInt32(claim.Value) : 0;
        }

        public static int GetSchoolId(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_SchoolId);
            return claim != null ? Convert.ToInt32(claim.Value) : 0;
        }

        public static string GetEmailId(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_EmailId);
            return claim?.Value ?? string.Empty;
        }

        public static string GetUserName(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_UserName);
            return claim?.Value ?? string.Empty;
        }

        public static string GetRoleId(this IIdentity identity)
        {
            var claimsIdentity = identity as ClaimsIdentity;
            var claim = claimsIdentity?.FindFirst(Common.SK_RoleId);
            return claim?.Value ?? string.Empty;
        }
    }
}
