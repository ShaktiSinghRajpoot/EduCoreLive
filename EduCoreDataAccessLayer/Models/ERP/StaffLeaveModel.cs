namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One leave request. Days are school working days on the School
    /// Calendar (weekly offs and holidays not counted); a half day is 0.5.</summary>
    public class StaffLeaveItem
    {
        public int       LeaveId      { get; set; }
        public int       StaffId      { get; set; }
        public string    FullName     { get; set; } = string.Empty;
        public string?   EmployeeCode { get; set; }
        public string?   Designation  { get; set; }

        public string    LeaveType    { get; set; } = string.Empty;
        public string? FromDate     { get; set; }
        public string? ToDate       { get; set; }
        public decimal   Days         { get; set; }
        public bool      HalfDay      { get; set; }
        public string?   Reason       { get; set; }

        /// <summary>Pending / Approved / Rejected / Cancelled.</summary>
        public string    Status       { get; set; } = "Pending";
        public string?   DecisionRemark { get; set; }
        public DateTime? AppliedAt    { get; set; }
        public DateTime? DecidedAt    { get; set; }
        public string?   CancelReason { get; set; }
        public DateTime? CancelledAt  { get; set; }

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
        public bool    Success { get; set; }
        public string  Message { get; set; } = string.Empty;
        public int     LeaveId { get; set; }
        public decimal Days    { get; set; }
    }

    /// <summary>One leave type's yearly balance for one staff member.
    /// Entitled / Remaining are null for uncapped types (Comp-off, Unpaid).</summary>
    public class StaffLeaveBalance
    {
        public string   LeaveType { get; set; } = string.Empty;
        public decimal? Entitled  { get; set; }
        public decimal  Taken     { get; set; }
        public decimal  Pending   { get; set; }
        public decimal? Remaining { get; set; }
        public int      Year      { get; set; }
    }
}
