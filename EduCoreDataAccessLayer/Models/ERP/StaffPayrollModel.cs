namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One staff member's payslip for one month.
    /// Gross is a SNAPSHOT taken when the payroll was run — a later salary revision
    /// must not rewrite a payslip the school has already issued.</summary>
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

        public decimal   Gross        { get; set; }
        /// <summary>Approved 'Unpaid' leave days falling inside this month.</summary>
        public int       LopDays      { get; set; }
        public decimal   LopAmount    { get; set; }
        public decimal   OtherDeduct  { get; set; }
        public decimal   NetPay       { get; set; }

        public string    Status       { get; set; } = "Draft";
        public DateTime? PaidAt       { get; set; }

        public decimal   TotalDeduct => LopAmount + OtherDeduct;
    }

    public class StaffPayrollResult
    {
        public bool   Success     { get; set; }
        public string Message     { get; set; } = string.Empty;
        public int    Generated   { get; set; }
        /// <summary>Payslips left alone because they were already paid.</summary>
        public int    Skipped     { get; set; }
        public int    WorkingDays { get; set; }
    }
}
