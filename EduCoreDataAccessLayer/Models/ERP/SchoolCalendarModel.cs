namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>A dated override on the school calendar (holiday, half day, or a working Saturday).</summary>
    public class SchoolCalendarEntry
    {
        public int     CalendarId { get; set; }
        public string  Date       { get; set; } = string.Empty;   // yyyy-MM-dd
        public string  DayType    { get; set; } = "holiday";      // holiday | half_day | working
        public string  Title      { get; set; } = string.Empty;
        public string? HalfDayEnd { get; set; }                   // HH:mm, half_day only
    }

    /// <summary>The calendar page's payload: the weekly pattern plus the dated overrides.</summary>
    public class SchoolCalendarData
    {
        public List<int> WeeklyOffDays { get; set; } = new() { 0 };   // 0 = Sunday … 6 = Saturday
        public List<SchoolCalendarEntry> Entries { get; set; } = new();
    }

    /// <summary>One day resolved against the weekly pattern + overrides — what the bell asks for.</summary>
    public class SchoolDayStatus
    {
        public string  Date       { get; set; } = string.Empty;   // yyyy-MM-dd
        public int     DayOfWeek  { get; set; }                   // 0 = Sunday (matches JS getDay)
        public string  DayType    { get; set; } = "working";      // working | weekly_off | holiday | half_day
        public string  Title      { get; set; } = string.Empty;
        public string? HalfDayEnd { get; set; }                   // HH:mm, half_day only
        public bool    IsWorking  { get; set; } = true;
    }

    /// <summary>One thing on the calendar besides the day type: a school event
    /// (PTM, function, trip ...) or an exam period from the Exam Schedule.</summary>
    public class SchoolEvent
    {
        public string  Kind      { get; set; } = "Event";   // Event | Exam
        public int     Id        { get; set; }
        public string  Title     { get; set; } = string.Empty;
        public string  EventType { get; set; } = "Event";   // PTM | Event | Sports | Trip | Meeting | Other | Exam
        public string  StartDate { get; set; } = string.Empty;   // yyyy-MM-dd
        public string  EndDate   { get; set; } = string.Empty;
        public string? StartTime { get; set; }               // HH:mm
        public string? EndTime   { get; set; }
        public string? ForWhom   { get; set; }               // events: free text; exams: the classes
        public string? Notes     { get; set; }
        public string? Status    { get; set; }               // exams only (Draft / Published ...)
    }

    public class SchoolCalendarSaveResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
    }
}
