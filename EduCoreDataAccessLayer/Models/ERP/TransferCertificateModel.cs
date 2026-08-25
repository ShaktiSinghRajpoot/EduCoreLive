using EduCoreDataAccessLayer.Models;

namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>What the issue form sends to mint a Transfer Certificate.</summary>
    public class TcIssueRequest
    {
        public int     StudentId { get; set; }
        public string? Format    { get; set; }   // Basic | Board
        public string? Conduct   { get; set; }   // Good | Satisfactory | Excellent
        public string? Result    { get; set; }   // e.g. "Promoted to Class VI"
        public string? Reason    { get; set; }   // reason for leaving (defaults to the exit reason)
        public string? Remarks   { get; set; }

        // Board-format extras (optional; only used by the Board template).
        public string? ExamResult      { get; set; }
        public string? FailedStatus    { get; set; }   // No | Once | Twice
        public string? SubjectsStudied { get; set; }
        public string? FeesPaidUpto    { get; set; }
        public int?    WorkingDays     { get; set; }
        public int?    DaysPresent     { get; set; }
        public string? Activities      { get; set; }
        public DateOnly? ApplicationDate { get; set; }
    }

    public class TcIssueResult
    {
        public bool    Success { get; set; }
        public string  Message { get; set; } = string.Empty;
        public int     TcId    { get; set; }
        public string? TcNo    { get; set; }
    }

    /// <summary>Payload for voiding a mistaken certificate.</summary>
    public class TcVoidRequest
    {
        public int     TcId   { get; set; }
        public string? Reason { get; set; }
    }

    /// <summary>
    /// One issued certificate, read back from the frozen register for printing.
    /// Every field is a snapshot taken at issue time — never recomputed.
    /// </summary>
    public class TransferCertificate
    {
        public int       TcId          { get; set; }
        public string    TcNo          { get; set; } = string.Empty;
        public string    Format        { get; set; } = "Standard";
        public DateOnly? IssueDate     { get; set; }
        public int       StudentId     { get; set; }

        public string?   AdmissionNo   { get; set; }
        public string    StudentName   { get; set; } = string.Empty;
        public string?   Gender        { get; set; }
        public DateOnly? Dob           { get; set; }
        public string?   FatherName    { get; set; }
        public string?   MotherName    { get; set; }
        public string?   ClassName     { get; set; }
        public string?   Section       { get; set; }
        public string?   AcademicYear  { get; set; }
        public DateOnly? AdmissionDate { get; set; }
        public DateOnly? DateOfLeaving { get; set; }
        public string?   Religion      { get; set; }
        public string?   Category      { get; set; }
        public string?   Nationality   { get; set; }
        public string?   Address       { get; set; }
        public string?   UdiseNo       { get; set; }

        public string?   ReasonForLeaving { get; set; }
        public string?   Conduct          { get; set; }
        public string?   Result           { get; set; }
        public string?   Remarks          { get; set; }
        public decimal   OutstandingAtIssue { get; set; }

        // Board-format extras (null on a Basic certificate).
        public string?   ExamResult      { get; set; }
        public string?   FailedStatus    { get; set; }
        public string?   SubjectsStudied { get; set; }
        public string?   FeesPaidUpto    { get; set; }
        public int?      WorkingDays     { get; set; }
        public int?      DaysPresent     { get; set; }
        public string?   Activities      { get; set; }
        public DateOnly? ApplicationDate { get; set; }

        public bool IsBoard => string.Equals(Format, "Board", StringComparison.OrdinalIgnoreCase);

        public int       PrintCount    { get; set; }
        public bool      IsVoid        { get; set; }

        /// <summary>True when this serve is a reprint — the page stamps DUPLICATE.</summary>
        public bool      WasDuplicate  { get; set; }

        public string ClassDisplay =>
            string.IsNullOrWhiteSpace(Section) ? (ClassName ?? "—") : $"{ClassName} - {Section}";
    }

    /// <summary>One row in the TC register list.</summary>
    public class TcListModel : ListModelBase
    {
        public int       TcId          { get; set; }
        public Guid      PublicId      { get; set; }
        public string    TcNo          { get; set; } = string.Empty;
        public string    Format        { get; set; } = "Standard";
        public DateOnly? IssueDate     { get; set; }
        public int       StudentId     { get; set; }
        public string?   AdmissionNo   { get; set; }
        public string    StudentName   { get; set; } = string.Empty;
        public string?   ClassName     { get; set; }
        public string?   Section       { get; set; }
        public string?   AcademicYear  { get; set; }
        public DateOnly? DateOfLeaving { get; set; }
        public bool      IsVoid        { get; set; }
        public int       PrintCount    { get; set; }

        public List<TcListModel> Items { get; set; } = new();

        public string ClassDisplay =>
            string.IsNullOrWhiteSpace(Section) ? (ClassName ?? "—") : $"{ClassName} - {Section}";
        public string IssueDateDisplay => IssueDate?.ToString("dd MMM yyyy") ?? "—";
    }
}
