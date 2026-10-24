namespace EduCoreDataAccessLayer.Models
{
    /// <summary>A "Book a free demo" enquiry from the public website (website_enquiry.sql).</summary>
    public class WebsiteEnquiry
    {
        public int EnquiryId { get; set; }
        public string ContactName { get; set; } = "";
        public string? Designation { get; set; }
        public string SchoolName { get; set; } = "";
        public string? City { get; set; }
        public string Phone { get; set; } = "";
        public string? Email { get; set; }
        public string? Students { get; set; }
        public string? Message { get; set; }
        public string Status { get; set; } = "New";
        public string? Note { get; set; }
        public string? CreatedAt { get; set; }
        public string? UpdatedAt { get; set; }
    }
}
