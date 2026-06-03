namespace educore.Models
{
    public class SchoolListModel
    {

        public int TenantId { get; set; }
        public string? TenantName { get; set; }
        public string? TenantCode { get; set; }
        // Basic
        public int SchoolId { get; set; }
        public string? SchoolName { get; set; }
        public string? DisplayName { get; set; }
        public string? SchoolCode { get; set; }

        // Board / Type
        public string? BoardName { get; set; }
        public string? SchoolTypeName { get; set; }

        // Location
        public string? City { get; set; }
        public string? State { get; set; }

        // Contact
        public string? ContactName { get; set; }
        public string? Phone { get; set; }

        // Status
        public string? StatusName { get; set; }

        // Dates
        public DateTime CreatedAt { get; set; }
    }
}