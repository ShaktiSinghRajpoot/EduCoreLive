using Microsoft.AspNetCore.Mvc.Rendering;

namespace EduCoreDataAccessLayer.Models.Admin
{
    // ── Base enquiry record ──────────────────────────────────────
    public class EnquiryModel
    {
        public int       EnquiryId              { get; set; }
        public int       TenantId               { get; set; }
        public int       SchoolId               { get; set; }
        // Student
        public string    StudentName            { get; set; } = string.Empty;
        public string?   Gender                 { get; set; }
        public DateOnly? Dob                    { get; set; }
        public string    ClassName              { get; set; } = string.Empty;
        public string    Session                { get; set; } = string.Empty;
        public string?   InterestedStream       { get; set; }   // Science / Commerce / Arts
        // Parent / Guardian
        public string?   ParentName             { get; set; }   // derived / legacy
        public string?   FatherName             { get; set; }
        public string?   FatherMobile           { get; set; }
        public string?   MotherName             { get; set; }
        public string?   MotherMobile           { get; set; }
        public string    Mobile                 { get; set; } = string.Empty;
        public string?   AltMobile              { get; set; }
        // Location
        public string?   City                   { get; set; }
        public string?   AreaLocality           { get; set; }
        // Lead
        public string    LeadSource             { get; set; } = "Walk-in";
        public string?   ReferrerName           { get; set; }
        public string?   ReferrerMobile         { get; set; }
        // CRM
        public string    Priority               { get; set; } = "Warm";
        public string    Status                 { get; set; } = "New";
        public int?      AssignedToId           { get; set; }
        public string?   LostReason             { get; set; }
        public string?   LostToSchool           { get; set; }
        // Dates
        public DateOnly  EnquiryDate            { get; set; } = DateOnly.FromDateTime(DateTime.Today);
        public DateOnly? NextFollowupDate        { get; set; }
        public string?   Notes                  { get; set; }
        // Fee / Registration
        public decimal?  EstimatedFee           { get; set; }
        public string?   RegistrationNumber     { get; set; }
        public DateOnly? RegistrationDate       { get; set; }
        public bool      RegistrationFeePaid    { get; set; }
        // Conversion
        public int?      AdmissionId            { get; set; }
        // Additional enquiry details (v2.1)
        public string?   ParentEmail            { get; set; }
        public string?   CurrentClass           { get; set; }   // class student is currently studying in
        public string?   CurrentSchool          { get; set; }   // school student is currently attending
        public bool      TransportRequired      { get; set; }   // needs school bus?
        public string?   WhatsAppNumber         { get; set; }   // WhatsApp if different from mobile
        // Audit
        public DateTime  CreatedAt              { get; set; }
        public DateTime  UpdatedAt              { get; set; }

        // Convenience: primary contact display name
        public string PrimaryParentDisplay =>
            !string.IsNullOrWhiteSpace(FatherName) ? FatherName :
            !string.IsNullOrWhiteSpace(ParentName) ? ParentName : "—";
    }

    // ── List row (adds computed display properties) ───────────────
    public class EnquiryListModel : EnquiryModel
    {
        public bool IsOverdue         { get; set; }
        public bool IsToday           { get; set; }
        public int  DaysSinceEnquiry  { get; set; }
        public int  FollowupCount     { get; set; }

        // Avatar
        public string StudentInitials  => BuildInitials(StudentName);
        public string AvatarColorClass => BuildAvatarColor(StudentName);

        // Pipeline key for JS filter
        public string PipelineKey => StatusToPipeline(Status);
        public string SourceKey   => SourceToKey(LeadSource);
        public string PriorityKey => Priority.ToLower();
        public string ClassKey    => ClassName.ToLower();
        public string SessionKey  => Session.ToLower();
        public string SearchKey   => $"{StudentName} {PrimaryParentDisplay} {Mobile}".ToLower();

        // Badges
        public string StatusBadgeClass => Status switch
        {
            "New"                    => "bg-label-primary",
            "Follow-up Pending"      => "bg-label-warning",
            "Interested"             => "bg-label-info",
            "Campus Visit Scheduled" => "bg-label-info",
            "Registration Done"      => "bg-label-secondary",
            "Admission Confirmed"    => "bg-label-success",
            "Not Interested"         => "bg-label-danger",
            "Dropped"                => "bg-label-danger",
            _                        => "bg-label-secondary"
        };

        public string PriorityBadgeClass => Priority switch
        {
            "Hot"  => "bg-label-danger",
            "Warm" => "bg-label-warning",
            _      => "bg-label-secondary"
        };

        // Source icon
        public string SourceIcon => LeadSource switch
        {
            "Walk-in"      => "bx-walk",
            "QR Code"      => "bx-qr",
            "Referral"     => "bx-user-plus",
            "Website"      => "bx-globe",
            "Phone Call"   => "bx-phone",
            "Social Media" => "bx-share-alt",
            _              => "bx-link"
        };

        // Follow-up display
        public string FollowupCssClass =>
            IsOverdue ? "followup-overdue" :
            IsToday   ? "followup-today"   :
            NextFollowupDate.HasValue ? "followup-upcoming" : "followup-done";

        public string FollowupDisplay =>
            IsOverdue             ? "Overdue"    :
            IsToday               ? "Due Today"  :
            NextFollowupDate.HasValue ? NextFollowupDate.Value.ToString("dd MMM yyyy") : "Done";

        public string FollowupIcon =>
            IsOverdue             ? "bx-error-circle" :
            IsToday               ? "bx-time"         :
            NextFollowupDate.HasValue ? string.Empty   : "bx-check-circle";

        public string FollowupSubtext =>
            IsOverdue             ? $"Was due {NextFollowupDate?.ToString("dd MMM yyyy")}" :
            IsToday               ? "Action required today" :
            NextFollowupDate.HasValue ? string.Empty          : "All caught up";

        // Days since label
        public string DaysSinceLabel =>
            DaysSinceEnquiry == 0 ? "Today" :
            DaysSinceEnquiry == 1 ? "Yesterday" :
            $"{DaysSinceEnquiry}d ago";

        // URLs
        public string WhatsAppUrl        => $"https://wa.me/91{Mobile.Trim()}";
        public string CallUrl            => $"tel:{Mobile.Trim()}";
        public string EstimatedFeeDisplay =>
            EstimatedFee.HasValue ? $"₹{EstimatedFee.Value:N0}" : "—";

        // Whether this status is terminal (no further changes allowed)
        public bool IsTerminal => Status is "Admission Confirmed";

        private static string BuildInitials(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return "?";
            var parts = name.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return parts.Length >= 2
                ? $"{char.ToUpper(parts[0][0])}{char.ToUpper(parts[1][0])}"
                : name.Length >= 2 ? name[..2].ToUpper() : name[..1].ToUpper();
        }

        private static string BuildAvatarColor(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return "bg-label-secondary text-secondary";
            return (char.ToUpper(name.Trim()[0]) % 5) switch
            {
                0 => "bg-label-primary text-primary",
                1 => "bg-label-info text-info",
                2 => "bg-label-success text-success",
                3 => "bg-label-warning text-warning",
                _ => "bg-label-danger text-danger"
            };
        }

        private static string StatusToPipeline(string status) => status switch
        {
            "New"                    => "new",
            "Follow-up Pending"      => "followup",
            "Interested"             => "interested",
            "Campus Visit Scheduled" => "campusvisit",
            "Registration Done"      => "registered",
            "Admission Confirmed"    => "admitted",
            "Not Interested"         => "notinterested",
            "Dropped"                => "notinterested",
            _                        => "new"
        };

        private static string SourceToKey(string source) => source switch
        {
            "Walk-in"      => "walkin",
            "QR Code"      => "qr",
            "Referral"     => "referral",
            "Website"      => "website",
            "Phone Call"   => "phonecall",
            "Social Media" => "socialmedia",
            _              => source.ToLower().Replace(" ", "").Replace("-", "")
        };
    }

    // ── KPI counts ───────────────────────────────────────────────
    public class EnquiryStatsModel
    {
        public int     TotalLeads       { get; set; }
        public int     DueToday         { get; set; }
        public int     OverdueCount     { get; set; }
        public int     CampusVisits     { get; set; }
        public int     Admitted         { get; set; }
        public int     CntNew           { get; set; }
        public int     CntFollowup      { get; set; }
        public int     CntInterested    { get; set; }
        public int     CntCampusVisit   { get; set; }
        public int     CntRegistered    { get; set; }
        public int     CntNotInterested { get; set; }
        public decimal ConversionRate   { get; set; }
    }

    // ── Follow-up log entry ──────────────────────────────────────
    public class EnquiryFollowupModel
    {
        public int       FollowupId         { get; set; }
        public int       EnquiryId          { get; set; }
        public DateTime  FollowupDate       { get; set; }
        public string    FollowupType       { get; set; } = "Call";
        public string?   Outcome            { get; set; }
        public string?   Notes              { get; set; }
        public DateOnly? NextFollowupDate   { get; set; }
        public string?   StatusBefore       { get; set; }
        public string?   StatusAfter        { get; set; }
        public int       CreatedBy          { get; set; }
        public DateTime  CreatedAt          { get; set; }

        public string TypeIcon => FollowupType switch
        {
            "Call"       => "bx-phone",
            "WhatsApp"   => "bxl-whatsapp",
            "Visit"      => "bx-walk",
            "Email"      => "bx-envelope",
            "In-Person"  => "bx-user",
            _            => "bx-chat"
        };

        public string OutcomeBadgeClass => Outcome switch
        {
            "Interested"       => "bg-label-success",
            "Not Interested"   => "bg-label-danger",
            "Call Back Later"  => "bg-label-warning",
            "Dropped"          => "bg-label-danger",
            _                  => "bg-label-secondary"
        };

        public string TimeAgo
        {
            get
            {
                var diff = DateTime.UtcNow - CreatedAt.ToUniversalTime();
                if (diff.TotalMinutes < 1)  return "Just now";
                if (diff.TotalMinutes < 60) return $"{(int)diff.TotalMinutes}m ago";
                if (diff.TotalHours   < 24) return $"{(int)diff.TotalHours}h ago";
                if (diff.TotalDays    < 7)  return $"{(int)diff.TotalDays}d ago";
                return CreatedAt.ToString("dd MMM yyyy");
            }
        }
    }

    // ── Status change audit entry ────────────────────────────────
    public class EnquiryStatusHistoryModel
    {
        public int      HistoryId   { get; set; }
        public int      EnquiryId   { get; set; }
        public string?  StatusFrom  { get; set; }
        public string   StatusTo    { get; set; } = string.Empty;
        public string?  ChangeNote  { get; set; }
        public int      ChangedBy   { get; set; }
        public DateTime CreatedAt   { get; set; }

        public string StatusToBadgeClass => StatusTo switch
        {
            "New"                    => "bg-label-primary",
            "Follow-up Pending"      => "bg-label-warning",
            "Interested"             => "bg-label-info",
            "Campus Visit Scheduled" => "bg-label-info",
            "Registration Done"      => "bg-label-secondary",
            "Admission Confirmed"    => "bg-label-success",
            "Not Interested"         => "bg-label-danger",
            "Dropped"                => "bg-label-danger",
            _                        => "bg-label-secondary"
        };
    }

    // ── Full page model ──────────────────────────────────────────
    public class EnquiryCrmPageModel
    {
        public List<EnquiryListModel>  Enquiries          { get; set; } = new();
        public EnquiryStatsModel       Stats              { get; set; } = new();
        public EnquiryModel            Form               { get; set; } = new();
        public List<SelectListItem>    AvailableClasses   { get; set; } = new();
        public int AvailableClassesid { get; set; } = new();

        public List<SelectListItem>    AvailableSessions  { get; set; } = new();
        public int AvailableSessionsid { get; set; } = new();
        public List<SelectListItem>    AvailableCounsellors { get; set; } = new();

        // Admission workflow settings — drive show/hide of the Registration stage.
        public AdmissionWorkflowModel  Workflow { get; set; } = new();
        // Pagination
        public int  PageNumber { get; set; } = 1;
        public int  PageSize   { get; set; } = 10;
        public int  TotalCount { get; set; } = 0;
        public int  TotalPages => TotalCount > 0
            ? (int)Math.Ceiling((double)TotalCount / PageSize) : 1;
    }
    // ── Request models ───────────────────────────────────────────
    public class LogFollowupRequest
    {
        public int EnquiryId { get; set; }
        public string FollowupType { get; set; } = "Call";
        public string? Outcome { get; set; }
        public string? Notes { get; set; }
        public string? NextFollowupDate { get; set; }
        public string? NewStatus { get; set; }
        public string? LostReason { get; set; }
    }

    public class UpdateStatusRequest
    {
        public int EnquiryId { get; set; }
        public string Status { get; set; } = string.Empty;
        public string? LostReason { get; set; }
    }

    public class DeleteEnquiryRequest
    {
        public int EnquiryId { get; set; }
    }

    public class RegisterEnquiryRequest
    {
        public int     EnquiryId           { get; set; }
        public string? RegistrationNumber  { get; set; }   // blank => auto-generate
        public string? RegistrationDate    { get; set; }   // blank => today
        public bool    RegistrationFeePaid { get; set; }
        public string? PaymentMode         { get; set; }   // Cash / UPI / Card / … (when fee collected)
        public string? PaymentReference    { get; set; }   // txn / cheque no (optional)
    }
}
