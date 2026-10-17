namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One staff member on the daily marking sheet.</summary>
    public class StaffDayRow
    {
        public int       StaffId      { get; set; }
        public string    FullName     { get; set; } = string.Empty;
        public string?   EmployeeCode { get; set; }
        public string?   Designation  { get; set; }
        public string?   StaffType    { get; set; }
        /// <summary>Present | Absent | HalfDay | Late | Leave, or null when not marked.</summary>
        public string?   Status       { get; set; }
        public string?   Remark       { get; set; }
        public DateTime? MarkedAt     { get; set; }
        /// <summary>Approved leave covering the date (e.g. "Sick"), or null.</summary>
        public string?   LeaveType    { get; set; }
    }

    public class StaffDaySheet
    {
        public List<StaffDayRow> Staff { get; set; } = new();
        /// <summary>School calendar entry for the date (e.g. "Holiday: Diwali"), or null.</summary>
        public string? CalendarNote { get; set; }
        public int     DayOfWeek    { get; set; }
    }

    /// <summary>Month register: the staff list and one mark per staff per day.</summary>
    public class StaffMonthRegister
    {
        public List<StaffDayRow> Staff { get; set; } = new();
        public List<StaffMonthMark> Marks { get; set; } = new();
    }

    public class StaffMonthMark
    {
        public int    StaffId { get; set; }
        public int    Day     { get; set; }
        public string Status  { get; set; } = string.Empty;
    }

    /// <summary>A period whose teacher is away on the date, with its substitute if one is set.</summary>
    public class SubstitutionNeed
    {
        public int     SectionId      { get; set; }
        public int     PeriodSeq      { get; set; }
        public string? PeriodLabel    { get; set; }
        public string  SectionLabel   { get; set; } = string.Empty;
        public string? SubjectName    { get; set; }
        public int     StaffId        { get; set; }
        public string  TeacherName    { get; set; } = string.Empty;
        public string? AwayReason     { get; set; }
        public int?    SubstituteId   { get; set; }
        public string? SubstituteName { get; set; }
    }

    /// <summary>A teacher's day: away or not, and the periods they already teach or cover.</summary>
    public class TeacherLoad
    {
        public int       StaffId    { get; set; }
        public string    FullName   { get; set; } = string.Empty;
        public string?   AwayReason { get; set; }
        public List<int> Busy       { get; set; } = new();
    }

    /// <summary>Staff Attendance > Staff report: one person over a date range.</summary>
    public class StaffAttendanceHistory
    {
        public List<StaffPick> Staff { get; set; } = new();
        public string? From { get; set; }
        public string? To { get; set; }
        public decimal WorkingDays { get; set; }
        public int Present  { get; set; }   // Present + Late
        public int Late     { get; set; }
        public int Absent   { get; set; }
        public int HalfDay  { get; set; }
        public int OnLeave  { get; set; }
        public int NotMarked { get; set; }
        public decimal Percent { get; set; } // of the days marked
        public List<StaffHistoryDay> Days { get; set; } = new();
    }

    public class StaffPick
    {
        public int     StaffId      { get; set; }
        public string  FullName     { get; set; } = string.Empty;
        public string? EmployeeCode { get; set; }
        public string? Designation  { get; set; }
        public bool    IsActive     { get; set; }
    }

    public class StaffHistoryDay
    {
        public string  Day       { get; set; } = string.Empty;
        public string  Weekday   { get; set; } = string.Empty;
        public string  DayType   { get; set; } = string.Empty;   // working | half_day | holiday | weekly_off
        public bool    Employed  { get; set; }
        public string? Status    { get; set; }
        public string? Remark    { get; set; }
        public string? LeaveType { get; set; }
    }

    /// <summary>A period a teacher covers for someone else (My Timetable).</summary>
    public class MySubstitution
    {
        public string  Date         { get; set; } = string.Empty;
        public string  DayLabel     { get; set; } = string.Empty;
        public int     PeriodSeq    { get; set; }
        public string? PeriodLabel  { get; set; }
        public string  SectionLabel { get; set; } = string.Empty;
        public string? SubjectName  { get; set; }
        public string? OriginalName { get; set; }
    }
}
