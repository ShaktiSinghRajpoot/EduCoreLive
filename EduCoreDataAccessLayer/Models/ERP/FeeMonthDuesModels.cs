namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>Month-wise fee dues for one session (fee_month_dues.sql).</summary>
    public class FeeMonthDues
    {
        public List<FeeDueMonth>   Months   { get; set; } = new();
        public List<FeeDueClass>   Classes  { get; set; } = new();
        public List<FeeDueStudent> Students { get; set; } = new();
    }

    public class FeeDueMonth
    {
        public string  Month     { get; set; } = string.Empty;   // yyyy-MM
        public decimal Due       { get; set; }
        public decimal Collected { get; set; }                   // paid + concession
        public decimal Pending   { get; set; }
        public int     Children  { get; set; }                   // with something pending in the month
    }

    public class FeeDueClass
    {
        public string  ClassName { get; set; } = string.Empty;
        public string  Section   { get; set; } = string.Empty;
        public int     Children  { get; set; }
        public int     WithDues  { get; set; }
        public decimal Pending   { get; set; }
    }

    public class FeeDueStudent
    {
        public int     StudentId    { get; set; }
        public string  PublicId     { get; set; } = string.Empty;
        public string  StudentName  { get; set; } = string.Empty;
        public string  AdmissionNo  { get; set; } = string.Empty;
        public string  GuardianName { get; set; } = string.Empty;
        public string  Mobile       { get; set; } = string.Empty;
        public string  ClassName    { get; set; } = string.Empty;
        public string  Section      { get; set; } = string.Empty;
        public string  RollNo       { get; set; } = string.Empty;
        public string  Status       { get; set; } = string.Empty;   // Active | Left | PassedOut ...
        public decimal Pending      { get; set; }
        public int     MonthsCount  { get; set; }
        public string  Months       { get; set; } = string.Empty;   // "2026-07,2026-08"
        public string  OldestMonth  { get; set; } = string.Empty;
        public string  LastPayment  { get; set; } = string.Empty;   // yyyy-MM-dd
        public string  LastPresent  { get; set; } = string.Empty;
        public int     ClassDays    { get; set; }                   // register taken, last 21 days
        public int     PresentDays  { get; set; }                   // the child present, last 21 days
        public bool    MayHaveLeft  { get; set; }
    }

    /// <summary>One child's attendance in a session, for the "may have left" check.</summary>
    public class AttendanceBrief
    {
        public string StudentName  { get; set; } = string.Empty;
        public string LastPresent  { get; set; } = string.Empty;
        public string LastMarked   { get; set; } = string.Empty;
        public int    AbsentStreak { get; set; }   // marked days since the last present day
        public int    Marked       { get; set; }
        public int    Present      { get; set; }
        public List<AttendanceMonth> Months { get; set; } = new();
    }

    public class AttendanceMonth
    {
        public string Month   { get; set; } = string.Empty;
        public int    Present { get; set; }
        public int    Absent  { get; set; }
        public int    OnLeave { get; set; }
    }
}
