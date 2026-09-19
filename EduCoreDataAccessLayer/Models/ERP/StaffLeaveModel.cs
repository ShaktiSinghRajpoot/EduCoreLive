namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One leave request. Days are working days — Sundays are not counted,
    /// matching the attendance register's definition of a school day.</summary>
    public class StaffLeaveItem
    {
        public int       LeaveId      { get; set; }
        public int       StaffId      { get; set; }
        public string    FullName     { get; set; } = string.Empty;
        public string?   EmployeeCode { get; set; }
        public string?   Designation  { get; set; }

        public string    LeaveType    { get; set; } = string.Empty;
        public DateOnly? FromDate     { get; set; }
        public DateOnly? ToDate       { get; set; }
        public int       Days         { get; set; }
        public string?   Reason       { get; set; }

        public string    Status       { get; set; } = "Pending";
        public string?   DecisionRemark { get; set; }
        public DateTime? AppliedAt    { get; set; }
        public DateTime? DecidedAt    { get; set; }

        /// <summary>Approved and today falls inside the range — the page's "on leave
        /// today" count. Decided in SQL so every caller agrees on what today is.</summary>
        public bool      OnLeaveToday { get; set; }

        /// <summary>Only 'Unpaid' leave costs the staff member anything; payroll
        /// charges those days as Loss of Pay.</summary>
        public bool IsUnpaid =>
            string.Equals(LeaveType, "Unpaid", System.StringComparison.OrdinalIgnoreCase);
    }

    public class StaffLeaveResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
        public int    LeaveId { get; set; }
        public int    Days    { get; set; }
    }
}
