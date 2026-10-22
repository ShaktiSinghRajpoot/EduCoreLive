using EduCoreDataAccessLayer.Helpers;
using EduCoreDataAccessLayer.Services.Contract.ERP;
using EduCoreDataAccessLayer.Services.Repository.ERP;
using Microsoft.AspNetCore.Mvc;

namespace educore.Helpers
{
    /// <summary>
    /// Parents' phone numbers, e-mail and home address: a teacher sees them only for the
    /// classes they teach (a timetable period or class teacher). Everyone else in the
    /// office -- the admin, anyone with students.manage, and staff who teach nothing
    /// (front desk, accounts) -- sees them for every student, as before.
    ///
    /// Usage in an action:
    ///   var allowed = await ContactAccess.AllowedSectionsAsync(this);
    ///   phone = ContactAccess.CanSee(allowed, s.ClassName, s.Section) ? s.Mobile : ContactAccess.Mask(s.Mobile)
    /// </summary>
    public static class ContactAccess
    {
        /// <summary>null = may see every student's contacts; otherwise the sections they may see.</summary>
        public static async Task<HashSet<string>?> AllowedSectionsAsync(Controller controller)
        {
            if (await HasPermissionAttribute.UserHasAsync(controller, "students.manage")) return null;

            var classTeacher = controller.HttpContext.RequestServices.GetRequiredService<IClassTeacherService>();
            var user = controller.User;
            int.TryParse(user.FindFirst(Common.SK_TenantId)?.Value, out var tenantId);
            int.TryParse(user.FindFirst(Common.SK_SchoolId)?.Value, out var schoolId);
            int.TryParse(user.FindFirst(Common.SK_UserId)?.Value, out var userId);

            var taught = await classTeacher.GetTaughtSectionsAsync(tenantId, schoolId, userId);
            return taught.Count == 0 ? null : taught;   // teaches nothing = office staff
        }

        public static bool CanSee(HashSet<string>? allowed, string? className, string? section) =>
            allowed == null || allowed.Contains(ClassTeacherService.SectionKey(className, section));

        /// <summary>98765 43210 -> XXXXXX3210; empty stays empty.</summary>
        public static string? Mask(string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return value;
            var digits = new string(value.Where(char.IsDigit).ToArray());
            return digits.Length >= 4 ? "XXXXXX" + digits[^4..] : "XXXX";
        }
    }
}
