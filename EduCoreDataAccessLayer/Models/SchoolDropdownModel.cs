namespace educore.Models
{
    public class SchoolDropdownModel
    {
        public List<DropdownItem> Statuses { get; set; } = new();
        public List<DropdownItem> Boards { get; set; } = new();
        public List<DropdownItem> SchoolTypes { get; set; } = new();
        public List<DropdownItem> OwnershipTypes { get; set; } = new();
        public List<DropdownItem> Mediums { get; set; } = new();
        public List<DropdownItem> AddressTypes { get; set; } = new();
        public List<DropdownItem> ContactTypes { get; set; } = new();
        public List<DropdownItem> AcademicYears { get; set; } = new();
        public List<DropdownItem> DateFormats { get; set; } = new();
        public List<DropdownItem> TimeFormats { get; set; } = new();
        public List<DropdownItem> Tenants { get; set; } = new();
    }
}
