namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>A slot in one weekday's bell schedule; only 'class' periods are bookable.</summary>
    public class TimetablePeriod
    {
        public int    DayOfWeek  { get; set; }                    // each day can run on its own schedule
        public int    PeriodSeq  { get; set; }
        public string Label      { get; set; } = string.Empty;
        public string PeriodType { get; set; } = "class";
        public string StartTime  { get; set; } = string.Empty;   // HH:mm
        public string EndTime    { get; set; } = string.Empty;   // HH:mm
    }

    public class TimetableSection
    {
        public int    SectionId   { get; set; }
        public string ClassName   { get; set; } = string.Empty;
        public string SectionName { get; set; } = string.Empty;
        public string Label       { get; set; } = string.Empty;  // "Class 10 – A"
        public string RoomNo      { get; set; } = string.Empty;
    }

    public class TimetableTeacher
    {
        public int    StaffId  { get; set; }
        public string FullName { get; set; } = string.Empty;
    }

    /// <summary>A day column — the week minus the school's weekly offs.</summary>
    public class TimetableDay
    {
        public int    DayOfWeek { get; set; }                    // 0 = Sunday … 6 = Saturday
        public string DayLabel  { get; set; } = string.Empty;
    }

    /// <summary>Everything the page needs once, on load.</summary>
    public class TimetableSetup
    {
        public List<TimetablePeriod>  Periods  { get; set; } = new();
        public List<TimetableSection> Sections { get; set; } = new();
        public List<TimetableTeacher> Teachers { get; set; } = new();
        public List<TimetableDay>     Days     { get; set; } = new();
    }

    /// <summary>One filled slot in a section's week.</summary>
    public class TimetableEntry
    {
        public int    DayOfWeek   { get; set; }
        public int    PeriodSeq   { get; set; }
        public int    SubjectId   { get; set; }
        public string SubjectName { get; set; } = string.Empty;
        public int?   StaffId     { get; set; }
        public string StaffName   { get; set; } = string.Empty;
        public string RoomNo      { get; set; } = string.Empty;
    }

    /// <summary>Another section's teacher booking — what the page flags a clash against.</summary>
    public class TimetableBusy
    {
        public int    DayOfWeek    { get; set; }
        public int    PeriodSeq    { get; set; }
        public int    StaffId      { get; set; }
        /// <summary>Room this booking occupies: the entry's own, else the section's.</summary>
        public string RoomNo       { get; set; } = string.Empty;
        public string SectionLabel { get; set; } = string.Empty;
    }

    public class TimetableGrid
    {
        public List<TimetableEntry> Entries  { get; set; } = new();
        public List<TimetableBusy>  Busy     { get; set; } = new();
        public List<SubjectItem>    Subjects { get; set; } = new();
    }

    /// <summary>Read-only teacher view: where one teacher is, slot by slot.</summary>
    public class TimetableTeacherEntry
    {
        public int    DayOfWeek    { get; set; }
        public int    PeriodSeq    { get; set; }
        public int    SubjectId    { get; set; }
        public string SubjectName  { get; set; } = string.Empty;
        public string SectionLabel { get; set; } = string.Empty;
        public string RoomNo       { get; set; } = string.Empty;
    }

    public class TimetableSaveResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
        public int    Copied  { get; set; }
        public int    Skipped { get; set; }
    }

    /// <summary>One live period of the School view (every section, one session).</summary>
    public class TimetableSchoolEntry
    {
        public int    SectionId   { get; set; }
        public int    DayOfWeek   { get; set; }
        public int    PeriodSeq   { get; set; }
        public int    SubjectId   { get; set; }
        public string SubjectName { get; set; } = string.Empty;
        public int?   StaffId     { get; set; }
        public string StaffName   { get; set; } = string.Empty;
    }

    /// <summary>A teacher's request for one period (academic.timetable_requests).</summary>
    public class TimetableRequestRow
    {
        public int    RequestId    { get; set; }
        public string Status       { get; set; } = string.Empty;   // Pending | Approved | Rejected
        public string Note         { get; set; } = string.Empty;   // why it was rejected
        public int    DayOfWeek    { get; set; }
        public int    PeriodSeq    { get; set; }
        public string PeriodLabel  { get; set; } = string.Empty;   // "Period 6"
        public int    SectionId    { get; set; }
        public string SectionLabel { get; set; } = string.Empty;
        public string SubjectName  { get; set; } = string.Empty;
        public string TeacherName  { get; set; } = string.Empty;
        public string LiveNow      { get; set; } = string.Empty;   // what is live in that slot today
        public string RequestedAt  { get; set; } = string.Empty;
    }
}
