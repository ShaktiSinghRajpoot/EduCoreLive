using System.ComponentModel.DataAnnotations;

namespace EduCoreDataAccessLayer.Models
{
    /// <summary>A role row (config.roles) for the Roles management screen.</summary>
    public class RoleModel
    {
        public int RoleId { get; set; }
        public string? RoleCode { get; set; }

        [Required(ErrorMessage = "Role name is required.")]
        [StringLength(50)]
        public string RoleName { get; set; } = string.Empty;

        [StringLength(250)]
        public string? Description { get; set; }

        public bool IsActive { get; set; } = true;

        /// <summary>True for the seeded roles (SCHOOL_ADMIN/TEACHER/…) — they can't be renamed or deleted.</summary>
        public bool IsBuiltin { get; set; }

        public int UserCount { get; set; }
        public int PermissionCount { get; set; }
    }

    /// <summary>One row of the global permission catalog (config.permissions).</summary>
    public class PermissionItem
    {
        public int PermissionId { get; set; }
        public string PermissionKey { get; set; } = string.Empty;  // e.g. "students.manage"
        public string ModuleGroup { get; set; } = string.Empty;
        public string DisplayName { get; set; } = string.Empty;    // e.g. "Students — Manage"
        public int SortOrder { get; set; }

        public string Feature => PermissionKey.Contains('.') ? PermissionKey[..PermissionKey.IndexOf('.')] : PermissionKey;
        public string Level => PermissionKey.Contains('.') ? PermissionKey[(PermissionKey.IndexOf('.') + 1)..] : string.Empty;
        public string FeatureLabel => DisplayName.Contains('—') ? DisplayName[..DisplayName.IndexOf('—')].Trim() : DisplayName;
    }

    /// <summary>One feature row in the permission matrix: View / Manage cells for a single feature.</summary>
    public class MatrixFeatureRow
    {
        public string FeatureLabel { get; set; } = string.Empty;
        public int? ViewId { get; set; }
        public int? ManageId { get; set; }
        public bool ViewGranted { get; set; }
        public bool ManageGranted { get; set; }
    }

    public class MatrixGroup
    {
        public string GroupName { get; set; } = string.Empty;
        public List<MatrixFeatureRow> Rows { get; set; } = new();
    }

    /// <summary>The full permission matrix for one role (catalog × current grants).</summary>
    public class RolePermissionMatrix
    {
        public int RoleId { get; set; }
        public string RoleName { get; set; } = string.Empty;
        public bool IsBuiltin { get; set; }
        public List<MatrixGroup> Groups { get; set; } = new();
    }

    /// <summary>A login user + their current primary role, for the Users & Roles screen.</summary>
    public class UserRoleItem
    {
        public int UserId { get; set; }
        public string FullName { get; set; } = string.Empty;
        public string? Email { get; set; }
        public string? Phone { get; set; }
        public int? RoleId { get; set; }
        public string? RoleName { get; set; }
        public string? RoleCode { get; set; }
    }
}
