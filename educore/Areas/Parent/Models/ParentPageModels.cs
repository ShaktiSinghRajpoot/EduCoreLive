using EduCoreDataAccessLayer.Models.ERP;

namespace educore.Areas.Parent.Models
{
    /// <summary>
    /// Which parent screens a child has. One place, used by the controller (to refuse
    /// a screen) and by the layout (to hide its tab), so the two cannot disagree.
    /// </summary>
    public static class ParentScreens
    {
        public static readonly string[] All =
            { "home", "attendance", "fees", "receipts", "results", "homework", "timetable", "notices" };

        public static string Label(string screen) => screen switch
        {
            "home"       => "Home",
            "attendance" => "Attendance",
            "fees"       => "Fees",
            "receipts"   => "Receipts",
            "results"    => "Results",
            "homework"   => "Homework",
            "timetable"  => "Timetable",
            "notices"    => "Notices",
            _            => screen
        };

        public static string Icon(string screen) => screen switch
        {
            "home"       => "bx-home",
            "attendance" => "bx-calendar-check",
            "fees"       => "bx-rupee",
            "receipts"   => "bx-receipt",
            "results"    => "bx-medal",
            "homework"   => "bx-book-open",
            "timetable"  => "bx-time-five",
            "notices"    => "bx-bell",
            _            => "bx-circle"
        };

        /// <summary>Null when the child has this screen, otherwise why not.</summary>
        public static string? Refusal(ParentChild c, string screen)
        {
            // A child who left keeps only receipts and results (12 months).
            if (!c.IsCurrent && screen is not ("home" or "receipts" or "results"))
                return "Only receipts and results are kept for a child who has left the school.";

            return screen switch
            {
                "attendance" => c.AttendanceOn ? null : NotInPlan("Attendance"),
                "fees"       => !c.FeesOn ? NotInPlan("Fees") : c.ShowFees ? null : TurnedOff("Fees"),
                "receipts"   => !c.FeesOn ? NotInPlan("Fees") : c.ShowReceipts ? null : TurnedOff("Receipts"),
                "results"    => !c.ExamsOn ? NotInPlan("Exams") : c.ShowResults ? null : TurnedOff("Results"),
                "homework"   => !c.AcademicsOn ? NotInPlan("Academics") : c.ShowHomework ? null : TurnedOff("Homework"),
                "timetable"  => !c.AcademicsOn ? NotInPlan("Academics") : c.ShowTimetable ? null : TurnedOff("Timetable"),
                "notices"    => c.ShowNotices ? null : TurnedOff("Notices"),
                _            => null
            };
        }

        private static string NotInPlan(string module) => $"{module} is not in your school's plan.";
        private static string TurnedOff(string screen) => $"Your school has not turned on {screen} for parents.";
    }

    public class ParentAttendancePage
    {
        public int Month { get; set; }
        public int Year  { get; set; }
        public StudentAttendanceSummary Summary { get; set; } = new();
        public string? TodayMark { get; set; }            // P / A / L, null = not marked yet
        public Dictionary<int, string> Holidays { get; set; } = new();   // day -> title
        public List<int> WeeklyOffDays { get; set; } = new();
    }

    public class ParentFeeLine
    {
        public string  Head        { get; set; } = string.Empty;
        public string? DueDate     { get; set; }
        public decimal Outstanding { get; set; }
        public bool    Overdue     { get; set; }
        public string? OldSession  { get; set; }          // "Dues of 2025-26"
    }

    public class ParentFeeMonth
    {
        public string Label { get; set; } = string.Empty;  // "Nov 2026"
        public List<ParentFeeLine> Lines { get; set; } = new();
        public decimal Total => Lines.Sum(l => l.Outstanding);
        public bool Overdue => Lines.Any(l => l.Overdue);
    }

    public class ParentFeesPage
    {
        public decimal DueNow  { get; set; }
        public decimal Later   { get; set; }
        public List<ParentFeeMonth> Months { get; set; } = new();
    }

    /// <summary>A receipt as parents see it: never who cancelled it or why.</summary>
    public class ParentReceiptRow
    {
        public string  ReceiptNo   { get; set; } = string.Empty;
        public string? Date        { get; set; }
        public decimal Amount      { get; set; }
        public string  Mode        { get; set; } = string.Empty;
        public bool    IsCancelled { get; set; }
    }

    public class ParentPrintHeader
    {
        public string SchoolName { get; set; } = string.Empty;
        public string Address    { get; set; } = string.Empty;
    }

    public class ParentReceiptPage
    {
        public ParentPrintHeader School { get; set; } = new();
        public FeeReceipt Receipt { get; set; } = new();
    }

    public class ParentResultsPage
    {
        public StudentExamResult Result { get; set; } = new();
        public int ExamId { get; set; }
        public string ExamName { get; set; } = string.Empty;
        public ParentPrintHeader School { get; set; } = new();
    }

    public class ParentTimetablePage
    {
        public List<TimetableEntry> Entries { get; set; } = new();
        public List<TimetablePeriod> Periods { get; set; } = new();
    }

    public class ParentNoticesPage
    {
        public List<ParentNotice> Notices { get; set; } = new();
        public List<SchoolEvent> Events { get; set; } = new();
        public List<SchoolCalendarEntry> Holidays { get; set; } = new();
    }
}
