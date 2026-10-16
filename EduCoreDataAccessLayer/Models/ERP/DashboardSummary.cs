namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>Everything the landing dashboard shows, in one round trip.</summary>
    public class DashboardSummary
    {
        public int     Students   { get; set; }
        public int     Staff      { get; set; }
        public decimal TodayCollection     { get; set; }
        public decimal YesterdayCollection { get; set; }
        public decimal Outstanding { get; set; }
        public int     DueStudents { get; set; }
        public int     OnLeaveToday { get; set; }

        /// <summary>Present today, over students whose class actually took a register.</summary>
        public int     PresentToday { get; set; }
        /// <summary>Students marked today at all. Zero means no register was taken —
        /// which is not the same as nobody turning up.</summary>
        public int     MarkedToday  { get; set; }

        /// <summary>
        /// False when the viewer lacks fees.view: the controller then empties every money
        /// figure and list (collections, outstanding, modes, defaulters, receipts) and the
        /// view hides those cards. Set by DashboardsController, not by the proc.
        /// </summary>
        public bool ShowFinance { get; set; } = true;

        // Same idea for the rest of the page: the controller turns each block off (and
        // empties its data) when the viewer's role cannot open that module.
        public bool ShowStudents   { get; set; } = true;   // students.view
        public bool ShowStaff      { get; set; } = true;   // staff.view
        public bool ShowLeave      { get; set; } = true;   // the Payroll & Leave module is on
        public bool ShowAttendance { get; set; } = true;   // attendance.view
        public bool CanAdmit       { get; set; } = true;   // students.manage
        public bool IsDriver       { get; set; }           // drives a bus -> My Bus shortcut
        public string? SessionName { get; set; }           // the school's current session
        public List<DashboardLink> QuickLinks { get; set; } = new();

        public List<DashboardTrendPoint>  Trend      { get; set; } = new();
        public List<DashboardClassCount>  Classes    { get; set; } = new();
        public List<DashboardModeTotal>   Modes      { get; set; } = new();
        public List<DashboardDefaulter>   Defaulters { get; set; } = new();
        public List<DashboardReceipt>     Recent     { get; set; } = new();
        public List<DashboardApproval>    Approvals  { get; set; } = new();
        public List<DashboardEvent>       Events     { get; set; } = new();
        public List<DashboardBirthday>    Birthdays  { get; set; } = new();
    }

    public class DashboardTrendPoint { public string Date { get; set; } public decimal Amount { get; set; } }
    public class DashboardClassCount  { public string ClassName { get; set; } = ""; public int Students { get; set; } }
    public class DashboardModeTotal   { public string Mode { get; set; } = ""; public decimal Amount { get; set; } }

    public class DashboardDefaulter
    {
        public int       StudentId   { get; set; }
        public Guid      PublicId    { get; set; }
        public string    StudentName { get; set; } = "";
        public string?   ClassName   { get; set; }
        public string?   Section     { get; set; }
        public decimal   Total       { get; set; }
        public decimal   Paid        { get; set; }
        public decimal   Due         { get; set; }
        public string? LastPayment { get; set; }
    }

    public class DashboardReceipt
    {
        public string    ReceiptNo   { get; set; } = "";
        public decimal   Amount      { get; set; }
        public string?   Mode        { get; set; }
        public string? PaymentDate { get; set; }
        public string    StudentName { get; set; } = "";
        public string?   ClassName   { get; set; }
    }

    public class DashboardApproval
    {
        public int       LeaveId   { get; set; }
        public string    FullName  { get; set; } = "";
        public string    LeaveType { get; set; } = "";
        public string? FromDate  { get; set; }
        public string? ToDate    { get; set; }
        public decimal   Days      { get; set; }
    }

    public class DashboardLink
    {
        public string Label { get; set; } = "";
        public string Icon  { get; set; } = "";
        public string Url   { get; set; } = "";
        public string Color { get; set; } = "";
    }

    public class DashboardEvent
    {
        public string Date    { get; set; }
        public string   Title   { get; set; } = "";
        public string?  DayType { get; set; }
    }

    public class DashboardBirthday
    {
        public string  Name   { get; set; } = "";
        public string  Who    { get; set; } = "";   // Student | Staff
        public string? Detail { get; set; }
    }
}
