using System.ComponentModel.DataAnnotations;

namespace EduCoreDataAccessLayer.Models
{
    /// <summary>
    /// One staff/employee record (Add / Edit / view). Backs core.staff. A staff
    /// member is an employee; only when <see cref="CreateLogin"/> is ticked does
    /// the save also create a login user (RoleId) and link core.staff.user_id.
    /// </summary>
    public class StaffModel
    {
        public int StaffId { get; set; }

        // ── Personal ───────────────────────────────────────────────
        public string? EmployeeCode { get; set; }

        [Required(ErrorMessage = "Full name is required.")]
        [StringLength(150)]
        public string FullName { get; set; } = string.Empty;

        public string? Gender { get; set; }

        [DataType(DataType.Date)]
        public DateTime? DateOfBirth { get; set; }

        [RegularExpression(@"^[6-9][0-9]{9}$", ErrorMessage = "Enter a valid 10-digit mobile number.")]
        public string? Mobile { get; set; }

        public string? AltMobile { get; set; }

        [EmailAddress(ErrorMessage = "Enter a valid email.")]
        public string? Email { get; set; }

        public string? BloodGroup { get; set; }
        public string? Address { get; set; }

        // ── Employment (3-layer taxonomy) ──────────────────────────
        public string? StaffType { get; set; }      // Teaching / Non-Teaching / Transport / Support
        public string? Department { get; set; }
        public string? Designation { get; set; }

        [DataType(DataType.Date)]
        public DateTime? JoiningDate { get; set; }

        public string? Qualification { get; set; }
        public int? ExperienceYears { get; set; }
        public string Status { get; set; } = "Active";

        // ── Payroll / bank ─────────────────────────────────────────
        public decimal? MonthlySalary { get; set; }
        public string? BankAccountNo { get; set; }
        public string? IfscCode { get; set; }
        public string? Pan { get; set; }
        public string? Aadhaar { get; set; }

        // ── Login linkage ──────────────────────────────────────────
        /// <summary>Existing linked login (read-only); null = no app access.</summary>
        public int? UserId { get; set; }

        /// <summary>Tick to also create a login for this staff member.</summary>
        public bool CreateLogin { get; set; }

        /// <summary>Plain password entered when CreateLogin is on (hashed in the controller).</summary>
        [DataType(DataType.Password)]
        public string? LoginPassword { get; set; }

        /// <summary>
        /// Role(s) granted to this person's login (config.roles.role_id). A user's
        /// effective permissions are the UNION of all their roles. On Edit, this is
        /// pre-filled with the user's current roles; on POST it's the checked set.
        /// </summary>
        public List<int> RoleIds { get; set; } = new();
    }

    /// <summary>Lightweight row for the staff list grid.</summary>
    public class StaffListItem
    {
        public int StaffId { get; set; }
        public string? EmployeeCode { get; set; }
        public string FullName { get; set; } = string.Empty;
        public string? Gender { get; set; }
        public string? Mobile { get; set; }
        public string? Email { get; set; }
        public string? StaffType { get; set; }
        public string? Department { get; set; }
        public string? Designation { get; set; }
        public DateTime? JoiningDate { get; set; }
        public string Status { get; set; } = "Active";
        public bool HasLogin { get; set; }
    }

    /// <summary>Form source lists for Add/Edit Staff.</summary>
    public class StaffDropdowns
    {
        public List<string> Departments { get; set; } = new();
        public List<DesignationOption> Designations { get; set; } = new();
        public List<RoleOption> Roles { get; set; } = new();
    }

    public class DesignationOption
    {
        public string Name { get; set; } = string.Empty;
        public string StaffType { get; set; } = string.Empty;
    }

    public class RoleOption
    {
        public int RoleId { get; set; }
        public string RoleName { get; set; } = string.Empty;
    }
}
