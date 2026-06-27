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
    }
}