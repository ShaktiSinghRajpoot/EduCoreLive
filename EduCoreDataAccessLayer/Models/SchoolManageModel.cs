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

        /// <summary>
        /// config.institution_categories: 1 School, 2 Computer / IT institute, 3 Coaching
        /// centre. Decides which boards / types / ownerships are offered and whether a
        /// board is required (only for a school -- checked in the controller and the proc).
        /// </summary>
        public int InstitutionCategoryId { get; set; } = 1;

        public int? BoardId { get; set; }

        /// <summary>
        /// Which state's board, for boards flagged config.boards.requires_state
        /// (State Board, Madrasah Board). NULL for CBSE/ICSE/IB/etc — the proc clears
        /// it when the chosen board doesn't need one. Points at config.states.
        /// </summary>
        public int? BoardStateId { get; set; }

        /// <summary>
        /// True for boards granted by a single state (State Board, Madrasah Board), from
        /// config.boards.requires_state. Such a school must sit in its board's state — a UP
        /// Board school cannot be in Bihar — so the address State is locked to the board
        /// state. National boards (CBSE/ICSE/IB/NIOS) leave it free.
        /// </summary>
        public bool BoardRequiresState { get; set; }

        [Required(ErrorMessage = "Type is required.")]
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
        // Letters-only rejected real Indian place names — "Hubballi-Dharwad",
        // "Y.S.R. Kadapa", "Bengaluru (Bangalore)". Allow the punctuation that
        // actually occurs, still block digits and symbols.
        [RegularExpression(@"^[A-Za-z][A-Za-z\s\.\-'()]*$", ErrorMessage = "Enter a valid city name.")]
        public string City { get; set; } = string.Empty;

        [StringLength(100)]
        public string? District { get; set; }

        [Required(ErrorMessage = "State is required.")]
        [StringLength(100)]
        public string State { get; set; } = string.Empty;

        // Geography ids from the shared Country/State/District master
        // (config.countries/states/districts — see Database/geo_master.sql).
        // The State/District text above is still posted and stored alongside these,
        // because every existing proc, list filter and report reads the varchar.
        public int? CountryId { get; set; }

        [Required(ErrorMessage = "State is required.")]
        public int? StateId { get; set; }

        public int? DistrictId { get; set; }

        [Required(ErrorMessage = "Pincode is required.")]
        [RegularExpression(@"^[1-9][0-9]{5}$", ErrorMessage = "Enter valid 6 digit pincode.")]
        public string Pincode { get; set; } = string.Empty;

        // The first digit of an Indian PIN code is its postal zone, and every zone
        // covers a fixed group of states. A cheap check that catches a Rajasthan
        // school typed with a Kerala PIN; it cannot catch a wrong district. Value =
        // the first digits allowed for that state (Puducherry's Yanam uses a 5 PIN).
        // Keyed by config.states name. Create.cshtml reads this same map.
        public static readonly Dictionary<string, string> PinZonesByState = new(StringComparer.OrdinalIgnoreCase)
        {
            ["Delhi"] = "1", ["Haryana"] = "1", ["Punjab"] = "1", ["Himachal Pradesh"] = "1",
            ["Jammu and Kashmir"] = "1", ["Ladakh"] = "1", ["Chandigarh"] = "1",
            ["Uttar Pradesh"] = "2", ["Uttarakhand"] = "2",
            ["Rajasthan"] = "3", ["Gujarat"] = "3", ["Dadra and Nagar Haveli and Daman and Diu"] = "3",
            ["Maharashtra"] = "4", ["Goa"] = "4", ["Madhya Pradesh"] = "4", ["Chhattisgarh"] = "4",
            ["Andhra Pradesh"] = "5", ["Telangana"] = "5", ["Karnataka"] = "5",
            ["Tamil Nadu"] = "6", ["Kerala"] = "6", ["Lakshadweep"] = "6", ["Puducherry"] = "56",
            ["West Bengal"] = "7", ["Odisha"] = "7", ["Sikkim"] = "7", ["Andaman and Nicobar Islands"] = "7",
            ["Assam"] = "7", ["Arunachal Pradesh"] = "7", ["Manipur"] = "7", ["Meghalaya"] = "7",
            ["Mizoram"] = "7", ["Nagaland"] = "7", ["Tripura"] = "7",
            ["Bihar"] = "8", ["Jharkhand"] = "8"
        };
        public const string PinStateMessage = "This pincode does not belong to the selected state.";

        // True when the PIN fits the state, or when either is blank / the state is not
        // in the map (a foreign state) -- the check never guesses.
        public static bool PinMatchesState(string? pincode, string? state)
        {
            if (string.IsNullOrWhiteSpace(pincode) || string.IsNullOrWhiteSpace(state)) return true;
            if (!PinZonesByState.TryGetValue(state.Trim(), out var zones)) return true;
            return zones.Contains(pincode.Trim()[0]);
        }

        public int ContactTypeId { get; set; } = 1;

        [Required(ErrorMessage = "Primary contact person is required.")]
        [StringLength(150, MinimumLength = 2, ErrorMessage = "Contact person name must be at least 2 characters.")]
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

        // The school admin password rule, kept in ONE place: the attribute below uses it
        // server-side and Create.cshtml reads the same constant for its client-side check.
        // At least 8 characters (ChangePasswordViewModel demands 8 on the forced first-login
        // reset) with at least one letter and one digit, so "12345678" is refused.
        public const string PasswordPattern = @"^(?=.*[A-Za-z])(?=.*[0-9]).{8,100}$";
        public const string PasswordRuleMessage = "Password must be at least 8 characters and include a letter and a digit.";

        [StringLength(100, MinimumLength = 8, ErrorMessage = "Password must be at least 8 characters.")]
        [RegularExpression(PasswordPattern, ErrorMessage = PasswordRuleMessage)]
        public string? Password { get; set; }

        public int? TenantId { get; set; }

        [Required(ErrorMessage = "Please select tenant option.")]
        public string TenantMode { get; set; } = "existing";

        [StringLength(200)]
        public string? TenantName { get; set; }

        // Same rule as sp_school_manage: a short slug such as "dps-group".
        [RegularExpression(@"^[A-Za-z0-9][A-Za-z0-9-]{1,49}$",
            ErrorMessage = "Tenant code may use only letters, digits and hyphens (2-50 characters).")]
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

        /// <summary>States/UTs for the "which state's board" picker (config.states).</summary>
        public List<SelectListItem> BoardStateList { get; set; } = new();

        /// <summary>
        /// Board ids that require a state. Driven by config.boards.requires_state, so the
        /// wizard never hardcodes "board 3 == State Board" — flag a new board in SQL and
        /// the UI follows.
        /// </summary>
        public List<int> BoardsRequiringState { get; set; } = new();
        public List<SelectListItem> SchoolTypeList { get; set; } = new();
        public List<SelectListItem> OwnershipTypeList { get; set; } = new();
        public List<SelectListItem> MediumList { get; set; } = new();
        public List<SelectListItem> AddressTypeList { get; set; } = new();
        public List<SelectListItem> ContactTypeList { get; set; } = new();
        public List<SelectListItem> AcademicYearList { get; set; } = new();
        public List<SelectListItem> DateFormatList { get; set; } = new();
        public List<SelectListItem> TimeFormatList { get; set; } = new();

        // Create School wizard: the raw lists, so each <option> can carry the categories
        // it belongs to (DropdownItem.Categories) and the page can filter by category.
        public List<InstitutionCategoryItem> CategoryList { get; set; } = new();
        public List<DropdownItem> BoardItems { get; set; } = new();
        public List<DropdownItem> SchoolTypeItems { get; set; } = new();
        public List<DropdownItem> OwnershipTypeItems { get; set; } = new();

        // Admin Basic Profile: what this school's category calls the board and type fields.
        public string? CategoryName { get; set; }
        public string BoardLabel { get; set; } = "Board";
        public string TypeLabel { get; set; } = "School Type";
    }
}