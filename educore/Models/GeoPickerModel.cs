namespace educore.Models
{
    /// <summary>
    /// Options for the shared Views/Shared/_StateDistrictCity.cshtml partial.
    ///
    /// Field names are parameters so the same partial serves every address form
    /// (school, student, staff, enquiry, transport) whatever its model calls the
    /// properties — the defaults match SchoolManageModel.
    /// </summary>
    public class GeoPickerModel
    {
        // ── Current values (edit forms) ─────────────────────────────────────
        public int? CountryId { get; set; }
        public int? StateId { get; set; }
        public int? DistrictId { get; set; }
        public string? City { get; set; }

        /// <summary>
        /// The free-text state already stored on a legacy row (e.g. "uttarpradesh").
        /// Shown as a warning under the dropdown when it has no matching StateId, so
        /// the user knows why the box looks empty on an existing record.
        /// </summary>
        public string? LegacyStateText { get; set; }

        // ── Posted field names ──────────────────────────────────────────────
        public string CountryFieldName { get; set; } = "CountryId";
        public string StateFieldName { get; set; } = "StateId";
        public string DistrictFieldName { get; set; } = "DistrictId";
        public string CityFieldName { get; set; } = "City";

        /// <summary>Hidden inputs that carry the selected text into the existing varchar columns.</summary>
        public string StateTextFieldName { get; set; } = "State";
        public string DistrictTextFieldName { get; set; } = "District";

        // ── Layout ──────────────────────────────────────────────────────────
        /// <summary>Country picker is hidden by default — 99% of schools are in India.</summary>
        public bool ShowCountry { get; set; }
        public bool ShowDistrict { get; set; } = true;
        public bool ShowCity { get; set; } = true;
        public bool StateRequired { get; set; } = true;

    /// <summary>
    /// Locks the State picker. Used when a school's board is granted by one state
    /// (State Board / Madrasah Board), where the address state follows the board and is
    /// not the school's to choose. The dropdown is disabled but still drives the district
    /// cascade; a hidden input carries the value, since a disabled control does not post.
    /// </summary>
    public bool StateReadOnly { get; set; }

    /// <summary>Explains why the State is locked, e.g. "Fixed by your board (State Board)".</summary>
    public string? StateReadOnlyNote { get; set; }
        public bool CityRequired { get; set; } = true;
        public bool DistrictRequired { get; set; }

        /// <summary>Bootstrap column class applied to each field.</summary>
        public string ColumnCss { get; set; } = "col-md-4";

        /// <summary>
        /// Suffix for the rendered element ids. Only matters when a page shows more than one
        /// picker (permanent + correspondence address) — without it both would render
        /// id="geoState" and every label's for= would point at the first one.
        /// </summary>
        public string InstanceId { get; set; } = "1";
    }
}
