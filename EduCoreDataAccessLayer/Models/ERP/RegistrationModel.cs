using Microsoft.AspNetCore.Mvc.Rendering;

using EduCoreDataAccessLayer.Helpers;

namespace EduCoreDataAccessLayer.Models.ERP
{
    // One row in the Registration Register.
    public class RegistrationListItem
    {
        public int       EnquiryId           { get; set; }
        public string?   RegistrationNumber  { get; set; }
        public string? RegistrationDate    { get; set; }
        public bool      RegistrationFeePaid { get; set; }
        public string    StudentName         { get; set; } = string.Empty;
        public string?   ClassName           { get; set; }
        public string?   Session             { get; set; }
        public string?   ParentName          { get; set; }
        public string?   Mobile              { get; set; }
        public string    Status              { get; set; } = string.Empty;
        public int?      AdmissionId         { get; set; }

        /// <summary>Newest live registration fee receipt (null when none).</summary>
        public string?   ReceiptNo           { get; set; }

        // Where the fee stands, from the receipts (never a stored flag).
        public decimal   FeeAmount           { get; set; }
        public decimal   SettledAmount       { get; set; }
        public decimal   BalanceAmount       { get; set; }

        /// <summary>Every registration receipt, cancelled ones included, oldest first.</summary>
        public List<RegistrationReceiptItem> Receipts { get; set; } = new();

        // Convenience flags for the UI.
        public bool IsAdmitted => AdmissionId.HasValue;
        public string RegistrationDateDisplay =>
            string.IsNullOrWhiteSpace(RegistrationDate) ? "—" : Dates.Show(RegistrationDate);
    }

    // One registration fee receipt, for reprint / cancel from the Registrations list.
    public class RegistrationReceiptItem
    {
        public string  ReceiptNo { get; set; } = string.Empty;
        public string? Date      { get; set; }
        public decimal Amount    { get; set; }
        public decimal Discount  { get; set; }
        public string? Mode      { get; set; }
        public bool    Cancelled { get; set; }
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
        public int     EnquiryId        { get; set; }
        // Part payments are allowed: null / 0 means "collect whatever is still owed".
        public decimal? CollectAmount   { get; set; }
        public string? PaymentMode      { get; set; }
        public string? PaymentReference { get; set; }
    }
}
