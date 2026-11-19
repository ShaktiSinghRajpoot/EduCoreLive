using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;

namespace educore.Helpers
{
    /// <summary>
    /// Names shared by the parent login (Areas/Parent) and Program.cs.
    ///
    /// Parents sign in with their OWN cookie scheme, not the staff one, so a staff
    /// policy can never match a parent and a parent page can never be opened with a
    /// staff cookie. The cookie only says which mobile signed in; the children that
    /// mobile may see are read again on every request (core.sp_parent_children).
    /// </summary>
    public static class ParentAuth
    {
        public const string Scheme      = "Parent";
        public const string Policy      = "ParentOnly";
        public const string Role        = "PARENT";
        public const string MobileClaim = "parent_mobile";

        /// <summary>The 10-digit mobile of the signed-in parent ("" when none).</summary>
        public static string Mobile(ClaimsPrincipal? user) =>
            user?.FindFirst(MobileClaim)?.Value ?? string.Empty;

        /// <summary>The last 10 digits of what was typed ("+91 98290-12345" -> "9829012345"); "" when fewer.</summary>
        public static string CleanMobile(string? typed)
        {
            var digits = new string((typed ?? string.Empty).Where(char.IsDigit).ToArray());
            return digits.Length >= 10 ? digits.Substring(digits.Length - 10) : string.Empty;
        }

        /// <summary>The stored form of a code: hashed with the mobile, so one code hash is no use for another number.</summary>
        public static string HashCode(string mobile, string code) =>
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(mobile + ":" + (code ?? string.Empty).Trim())));

        /// <summary>"9829012345" -> "XXXXXX2345".</summary>
        public static string Masked(string? mobile) =>
            string.IsNullOrEmpty(mobile) || mobile.Length < 4 ? "" : "XXXXXX" + mobile.Substring(mobile.Length - 4);
    }
}
