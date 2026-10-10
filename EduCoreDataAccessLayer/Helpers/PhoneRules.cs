using System.Text.RegularExpressions;

namespace EduCoreDataAccessLayer.Helpers
{
    /// <summary>
    /// A school's official number is often a landline, so it accepts either:
    ///   * a 10-digit Indian mobile        9876543210
    ///   * a landline with its STD code    0141-2345678, 011 23456789, 01412345678
    ///     (starts with 0, 10 to 12 digits in all)
    /// Spaces and hyphens are ignored, and the number is stored as DIGITS ONLY.
    ///
    /// The same rule lives in core.fn_school_phone_clean (sp_school_admin_basic_profile_manage.sql)
    /// and EC.rule.phone (site.js) — change all three together.
    /// </summary>
    public static class PhoneRules
    {
        public const string Message = "Enter a 10-digit mobile number or a landline with STD code (e.g. 0141-2345678).";

        private static readonly Regex Mobile   = new(@"^[6-9][0-9]{9}$");
        private static readonly Regex Landline = new(@"^0[0-9]{9,11}$");

        /// <summary>Digits only, or null when the value is blank.</summary>
        public static string? Clean(string? value)
        {
            var digits = Regex.Replace(value ?? "", @"[\s-]", "");
            return digits.Length == 0 ? null : digits;
        }

        /// <summary>True for a mobile or a landline (blank is NOT valid — check required separately).</summary>
        public static bool IsValid(string? value)
        {
            var v = Clean(value);
            return v != null && (Mobile.IsMatch(v) || Landline.IsMatch(v));
        }
    }
}
