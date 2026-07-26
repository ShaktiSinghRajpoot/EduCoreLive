namespace educore.Models
{
    public class UserViewModel
    {
        public int UserId { get; set; }
        public int? TenantId { get; set; }
        public int? SchoolId { get; set; }

        public string? Email { get; set; }
        public string? Password { get; set; }

        public string? FullName { get; set; }
        public string? Phone { get; set; }

        public int RoleId { get; set; }
        public string? RoleCode { get; set; }
        public string? RoleName { get; set; }

        public bool IsActive { get; set; }
        public bool IsDeleted { get; set; }
        public bool RememberMe { get; set; }
        public bool MustChangePassword { get; set; }

        public string? PasswordHash { get; set; }

        // ── School gate (GET_LOGIN_USER only) ───────────────────────────────
        // Whether this user's school currently permits sign-in. Driven by
        // config.school_statuses.allows_login, plus a hard block when the school
        // row is deleted or inactive. Super admins (school_id = 0) are always true.
        // Checked in AccountController AFTER the password verifies — never before,
        // or the message becomes an email-enumeration vector.
        public bool SchoolAllowsLogin { get; set; } = true;

        /// <summary>ACTIVE / UNDER_REVIEW / INACTIVE / SUSPENDED / CLOSED / PENDING.</summary>
        public string? SchoolStatusCode { get; set; }

        /// <summary>Why sign-in was refused, from config.school_statuses.login_message.</summary>
        public string? SchoolLoginMessage { get; set; }
    }
}