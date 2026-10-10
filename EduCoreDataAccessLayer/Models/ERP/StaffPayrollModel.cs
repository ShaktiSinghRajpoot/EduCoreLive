namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One staff member's payslip for one month.
    /// Every figure is a SNAPSHOT taken when the payroll was run — a later salary
    /// revision must not rewrite a payslip the school has already issued, and a
    /// paid payslip can never change at all (a trigger refuses it).</summary>
    public class StaffPayrollItem
    {
        public int       PayrollId    { get; set; }
        public int       StaffId      { get; set; }
        public string    FullName     { get; set; } = string.Empty;
        public string?   EmployeeCode { get; set; }
        public string?   Designation  { get; set; }
        public string?   Department   { get; set; }

        public int       PayMonth     { get; set; }
        public int       PayYear      { get; set; }

        /// <summary>The monthly salary the payslip was worked from.</summary>
        public decimal   MonthlySalary { get; set; }
        /// <summary>School working days in the month, and how many of them the
        /// person was employed (less for a joiner or a leaver).</summary>
        public decimal   WorkingDays  { get; set; }
        public decimal   PaidDays     { get; set; }

        /// <summary>Earned for the employed days (= salary for a full month).</summary>
        public decimal   Gross        { get; set; }
        /// <summary>Approved 'Unpaid' leave days falling inside this month.</summary>
        public decimal   LopDays      { get; set; }
        public decimal   LopAmount    { get; set; }
        public decimal   OtherAdd     { get; set; }
        public decimal   OtherDeduct  { get; set; }
        public decimal   NetPay       { get; set; }

        public string    Status       { get; set; } = "Draft";
        public DateTime? GeneratedAt  { get; set; }
        public DateTime? PaidAt       { get; set; }
        public string?   PaymentMode  { get; set; }
        public string?   PaymentReference { get; set; }
        public string?   PaidByName   { get; set; }

        public decimal   TotalDeduct => LopAmount + OtherDeduct;
    }

    public class StaffPayrollResult
    {
        public bool    Success     { get; set; }
        public string  Message     { get; set; } = string.Empty;
        public int     Generated   { get; set; }
        /// <summary>Payslips left alone because they were already paid.</summary>
        public int     Skipped     { get; set; }
        public decimal WorkingDays { get; set; }
        public int     AdjustmentId { get; set; }
    }

    /// <summary>An addition, deduction or advance against one staff member's month.
    /// Never edited; voided with a reason while the month is unpaid.</summary>
    public class StaffPayrollAdjustment
    {
        public int       AdjustmentId { get; set; }
        public int       StaffId      { get; set; }
        public string    FullName     { get; set; } = string.Empty;
        public string?   EmployeeCode { get; set; }
        public string    Kind         { get; set; } = string.Empty;
        public decimal   Amount       { get; set; }
        public string    Reason       { get; set; } = string.Empty;
        public string?   PaymentMode  { get; set; }
        public string?   PaymentReference { get; set; }
        public DateTime? CreatedAt    { get; set; }
        public string?   CreatedByName { get; set; }
        public bool      IsVoid       { get; set; }
        public DateTime? VoidedAt     { get; set; }
        public string?   VoidReason   { get; set; }
    }

    /// <summary>One event in a payslip's money trail (append-only).</summary>
    public class StaffPayrollHistory
    {
        public string    Action       { get; set; } = string.Empty;
        public decimal?  NetPay       { get; set; }
        public string?   PaymentMode  { get; set; }
        public string?   PaymentReference { get; set; }
        public string?   Note         { get; set; }
        public DateTime? ActionAt     { get; set; }
        public string?   ActionByName { get; set; }
    }
}
