using EduCoreDataAccessLayer.Models;

namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One row on the "Inactive / Left" page. A student who leaves is kept, not
    /// deleted — the fee ledger and (later) the TC register still point at them.
    /// </summary>
    public class StudentExitListModel : ListModelBase
    {
        public int      StudentId      { get; set; }
        public string?  AdmissionNo    { get; set; }
        public string   StudentName    { get; set; } = string.Empty;
        public string?  ClassName      { get; set; }
        public string?  Section        { get; set; }
        public string?  AcademicYear   { get; set; }
        public string?  GuardianName   { get; set; }
        public string?  Mobile         { get; set; }
        public DateOnly? AdmissionDate  { get; set; }
        public DateOnly? DateOfLeaving  { get; set; }

        /// <summary>Transfer | Passout | Struck Off | Withdrawn.</summary>
        public string   Status         { get; set; } = string.Empty;
        public string?  LeavingReason  { get; set; }
        public decimal  Outstanding    { get; set; }

        // Filters
        public string?  FilterStatus   { get; set; }
        public string?  FilterDues     { get; set; }   // pending | clear

        // Tiles (window aggregates over the whole filtered set, not just this page)
        public int TransferCount { get; set; }
        public int PassoutCount  { get; set; }
        public int DuesCount     { get; set; }

        public List<StudentExitListModel> Items { get; set; } = new();

        public string ClassDisplay =>
            string.IsNullOrWhiteSpace(Section) ? (ClassName ?? "—") : $"{ClassName} - {Section}";
        public string DateOfLeavingDisplay => DateOfLeaving?.ToString("dd MMM yyyy") ?? "—";
        public bool   DuesPending          => Outstanding > 0;
    }

    /// <summary>Payload for marking a student as having left.</summary>
    public class StudentExitRequest
    {
        public int      StudentId     { get; set; }
        public string   Status        { get; set; } = string.Empty;   // Transfer | Passout | Struck Off | Withdrawn
        public DateOnly? DateOfLeaving { get; set; }
        public string?  Reason        { get; set; }
    }

    public class StudentExitResult
    {
        public bool    Success     { get; set; }
        public string  Message     { get; set; } = string.Empty;
        /// <summary>Dues still owed when the student left — reported, not blocking.</summary>
        public decimal Outstanding { get; set; }
    }
}
