using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Models.Admin
{
    // One row in the Registration Register.
    public class RegistrationListItem
    {
        public int       EnquiryId           { get; set; }
        public string?   RegistrationNumber  { get; set; }
        public DateOnly? RegistrationDate    { get; set; }
        public bool      RegistrationFeePaid { get; set; }
        public string    StudentName         { get; set; } = string.Empty;
        public string?   ClassName           { get; set; }
        public string?   Session             { get; set; }
        public string?   ParentName          { get; set; }
        public string?   Mobile              { get; set; }
        public string    Status              { get; set; } = string.Empty;
        public int?      AdmissionId         { get; set; }

        // Convenience flags for the UI.
        public bool IsAdmitted => AdmissionId.HasValue;
        public string RegistrationDateDisplay =>
            RegistrationDate?.ToString("dd MMM yyyy") ?? "—";
    }

    public class RegistrationStats
    {
        public int TotalRegistered { get; set; }
        public int FeeCollected    { get; set; }
        public int FeePending      { get; set; }
        public int Converted       { get; set; }
    }

    // Page model for the Registration Register screen.
    public class RegistrationPageModel
    {
        public RegistrationStats        Stats             { get; set; } = new();
        public List<SelectListItem>     AvailableSessions { get; set; } = new();
        public List<SelectListItem>     AvailableClasses  { get; set; } = new();

        // Surfaced so the screen can show fee columns/actions only when relevant.
        public bool RegistrationFeeEnabled { get; set; }
    }

    public class CancelRegistrationRequest
    {
        public int     EnquiryId { get; set; }
        public string? Reason    { get; set; }
    }

    public class MarkRegistrationFeeRequest
    {
        public int EnquiryId { get; set; }
    }
}
