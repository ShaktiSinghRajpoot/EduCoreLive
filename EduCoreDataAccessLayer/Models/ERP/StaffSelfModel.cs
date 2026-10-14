namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>The signed-in user's own staff row (My Leave / My Payslip).</summary>
    public class MyStaffInfo
    {
        public int     StaffId      { get; set; }
        public string  FullName     { get; set; } = string.Empty;
        public string? EmployeeCode { get; set; }
        public string? Designation  { get; set; }
        public string? Department   { get; set; }
        public string  Status       { get; set; } = string.Empty;
        public string? JoiningDate  { get; set; }
        public string? StaffType    { get; set; }   // Teaching / Non-Teaching / Transport ...

        /// <summary>No type recorded counts as teaching, so nobody loses My Timetable by accident.</summary>
        public bool IsTeachingType => string.IsNullOrWhiteSpace(StaffType)
                                   || string.Equals(StaffType, "Teaching", System.StringComparison.OrdinalIgnoreCase);

        /// <summary>Active or "On Leave": can still apply. Inactive staff can only read.</summary>
        public bool IsCurrent => !string.Equals(Status, "Inactive", System.StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>One of my own leave requests, with who applied / decided / cancelled it.</summary>
    public class MyLeaveItem : StaffLeaveItem
    {
        public string? AppliedByName   { get; set; }
        public string? DecidedByName   { get; set; }
        public string? CancelledByName { get; set; }

        /// <summary>Worked out by the proc with the same rule CANCEL enforces.</summary>
        public bool    CanCancel       { get; set; }
    }

    /// <summary>One of my own payslips. The payment reference and who paid it are
    /// never loaded for self-service; the mode and date are.</summary>
    public class MyPayslip : StaffPayrollItem
    {
        public string? SchoolName { get; set; }
    }
}
