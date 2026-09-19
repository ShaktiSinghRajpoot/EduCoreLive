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

        public List<DashboardTrendPoint>  Trend      { get; set; } = new();
        public List<DashboardClassCount>  Classes    { get; set; } = new();
        public List<DashboardModeTotal>   Modes      { get; set; } = new();
        public List<DashboardDefaulter>   Defaulters { get; set; } = new();
        public List<DashboardReceipt>     Recent     { get; set; } = new();
        public List<DashboardApproval>    Approvals  { get; set; } = new();
        public List<DashboardEvent>       Events     { get; set; } = new();
        public List<DashboardBirthday>    Birthdays  { get; set; } = new();
    }

    public class DashboardTrendPoint { public DateOnly Date { get; set; } public decimal Amount { get; set; } }
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
        public DateOnly? LastPayment { get; set; }
    }

    public class DashboardReceipt
    {
        public string    ReceiptNo   { get; set; } = "";
        public decimal   Amount      { get; set; }
        public string?   Mode        { get; set; }
        public DateOnly? PaymentDate { get; set; }
        public string    StudentName { get; set; } = "";
        public string?   ClassName   { get; set; }
    }

    public class DashboardApproval
    {
        public int       LeaveId   { get; set; }
        public string    FullName  { get; set; } = "";
        public string    LeaveType { get; set; } = "";
        public DateOnly? FromDate  { get; set; }
        public DateOnly? ToDate    { get; set; }
        public int       Days      { get; set; }
    }

    public class DashboardEvent
    {
        public DateOnly Date    { get; set; }
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
