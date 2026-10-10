namespace EduCoreDataAccessLayer.Models.ERP
{
    // Whole-ledger totals for one student (core.sp_student_fee_totals).
    // TotalDue is what is still billed after closed instalments are taken off;
    // TotalClosed is what was taken off (student left, bus removed, class changed).
    public class StudentFeeTotals
    {
        public decimal TotalDue        { get; set; }
        public decimal TotalPaid       { get; set; }
        public decimal TotalConcession { get; set; }
        public decimal TotalRefunded   { get; set; }
        public decimal TotalClosed     { get; set; }
        public decimal Outstanding     { get; set; }
        public decimal AdvanceBalance  { get; set; }
    }

    // One line of a student's history (core.sp_student_history_get).
    public class StudentHistoryItem
    {
        public string? HappenedAt { get; set; }
        public string  Action     { get; set; } = string.Empty;
        public string? Detail     { get; set; }
        public decimal? Amount    { get; set; }
        public string? DoneBy     { get; set; }
    }
}
