namespace EduCoreDataAccessLayer.Models.Admin
{
    /// <summary>
    /// One outstanding installment from <c>core.student_ledger</c>, used by the
    /// Fee Collection counter to list a student's dues.
    /// </summary>
    public class StudentDueItem
    {
        public int       LedgerId         { get; set; }
        public string    FeeHeadName      { get; set; } = string.Empty;
        public string    Frequency        { get; set; } = string.Empty;
        public string?   InstallmentLabel { get; set; }
        public DateOnly? DueDate          { get; set; }
        public decimal   AmountDue        { get; set; }
        public decimal   AmountPaid       { get; set; }
        public decimal   Outstanding      { get; set; }
    }
}
