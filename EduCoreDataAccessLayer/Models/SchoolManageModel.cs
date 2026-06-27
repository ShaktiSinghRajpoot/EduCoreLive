using Microsoft.AspNetCore.Mvc.Rendering;
using System.ComponentModel.DataAnnotations;

namespace educore.Models
{
    public class SchoolManageModel
    {
        public string Operation { get; set; } = "INSERT";
        public int? SchoolId { get; set; }

        [Required(ErrorMessage = "School name is required.")]
        [StringLength(200, ErrorMessage = "School name cannot exceed 200 characters.")]
        public string SchoolName { get; set; } = string.Empty;

        [StringLength(200)]
        public string? DisplayName { get; set; }

        [Required(ErrorMessage = "Status is required.")]
        public int StatusId { get; set; }

        [Required(ErrorMessage = "Board is required.")]
        public int? BoardId { get; set; }

        [Required(ErrorMessage = "School type is required.")]
        public int? SchoolTypeId { get; set; }

        public int? OwnershipTypeId { get; set; }
        public int? MediumId { get; set; }

        [StringLength(100)]
        public string? RegistrationNumber { get; set; }

        [StringLength(100)]
        public string? AffiliationNumber { get; set; }

        [Range(1800, 2100, ErrorMessage = "Enter valid established year.")]
        public int? EstablishedYear { get; set; }

        [Url(ErrorMessage = "Enter valid website URL.")]
        [StringLength(200)]
        public string? Website { get; set; }

        public int AddressTypeId { get; set; } = 1;

        [Required(ErrorMessage = "Address is required.")]
        [StringLength(250)]
        public string AddressLine1 { get; set; } = string.Empty;

        [StringLength(250)]
        public string? AddressLine2 { get; set; }

        [Required(ErrorMessage = "City is required.")]
        [StringLength(100)]
        [RegularExpression(@"^[A-Za-z\s]+$", ErrorMessage = "City must contain only letters.")]
        public string City { get; set; } = string.Empty;

        [StringLength(100)]
        public string? District { get; set; }

        [Required(ErrorMessage = "State is required.")]
        [StringLength(100)]
        public string State { get; set; } = string.Empty;

        [Required(ErrorMessage = "Pincode is required.")]
        [RegularExpression(@"^[1-9][0-9]{5}$", ErrorMessage = "Enter valid 6 digit pincode.")]
        public string Pincode { get; set; } = string.Empty;

        public int ContactTypeId { get; set; } = 1;

        [Required(ErrorMessage = "Contact name is required.")]
        [StringLength(150)]
        public string ContactName { get; set; } = string.Empty;

        [StringLength(100)]
        public string? Designation { get; set; }

        [EmailAddress(ErrorMessage = "Enter valid contact email.")]
        [StringLength(150)]
        public string? ContactEmail { get; set; }

        [Required(ErrorMessage = "Phone number is required.")]
        [RegularExpression(@"^[6-9][0-9]{9}$", ErrorMessage = "Enter valid 10 digit Indian mobile number.")]
        public string Phone { get; set; } = string.Empty;

        [RegularExpression(@"^[6-9][0-9]{9}$", ErrorMessage = "Enter valid alternate phone number.")]
        public string? AlternatePhone { get; set; }

        public int? AcademicYearId { get; set; }
        public int? DateFormatId { get; set; }
        public int? TimeFormatId { get; set; }

        public bool EnableSms { get; set; }
        public bool EnableEmail { get; set; } = true;
        public bool EnableWhatsapp { get; set; }

        public int? AdminUserId { get; set; }

        public bool CreateSchoolAdmin { get; set; } = true;

        [StringLength(150, MinimumLength = 3, ErrorMessage = "Admin name must be at least 3 characters.")]
        public string? AdminFullName { get; set; }

        [EmailAddress(ErrorMessage = "Enter valid admin email.")]
        [StringLength(150)]
        public string? AdminEmail { get; set; }

        [RegularExpression(@"^[6-9][0-9]{9}$", ErrorMessage = "Enter valid admin phone number.")]
        public string? AdminPhone { get; set; }

        public bool AutoGeneratePassword { get; set; } = true;

        [StringLength(100, MinimumLength = 6, ErrorMessage = "Password must be at least 6 characters.")]
        public string? Password { get; set; }

        public int? TenantId { get; set; }

        [Required(ErrorMessage = "Please select tenant option.")]
        public string TenantMode { get; set; } = "existing";

        [StringLength(200)]
        public string? TenantName { get; set; }

        [StringLength(50, ErrorMessage = "Tenant code cannot exceed 50 characters.")]
        public string? TenantCode { get; set; }

        [EmailAddress(ErrorMessage = "Enter valid tenant email.")]
        [StringLength(150)]
        public string? TenantEmail { get; set; }

        [RegularExpression(@"^[6-9][0-9]{9}$", ErrorMessage = "Enter valid tenant phone.")]
        public string? TenantPhone { get; set; }

        public int UserId { get; set; }
        // Display-only fields for Admin Basic Profile
        public string? SchoolCode { get; set; }
        public string? BoardName { get; set; }
        public string? SchoolTypeName { get; set; }
        public string? StatusName { get; set; }

        // Image paths
        public string? LogoUrl { get; set; }
        public string? HeaderImageUrl { get; set; }
        public List<SelectListItem> TenantList { get; set; } = new();
        public List<SelectListItem> StatusList { get; set; } = new();
        public List<SelectListItem> BoardList { get; set; } = new();
        public List<SelectListItem> SchoolTypeList { get; set; } = new();
        public List<SelectListItem> OwnershipTypeList { get; set; } = new();
        public List<SelectListItem> MediumList { get; set; } = new();
        public List<SelectListItem> AddressTypeList { get; set; } = new();
        public List<SelectListItem> ContactTypeList { get; set; } = new();
        public List<SelectListItem> AcademicYearList { get; set; } = new();
        public List<SelectListItem> DateFormatList { get; set; } = new();
        public List<SelectListItem> TimeFormatList { get; set; } = new();
    }
}