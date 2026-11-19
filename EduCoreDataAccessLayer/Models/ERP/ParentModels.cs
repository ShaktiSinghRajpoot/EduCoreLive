namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One child linked to a parent's mobile (core.sp_parent_children). The parent
    /// pages take a child ONLY from this list -- see educore/docs/PARENT-MODULE.md.
    /// </summary>
    public class ParentChild
    {
        public int     StudentId    { get; set; }
        public int     TenantId     { get; set; }
        public int     SchoolId     { get; set; }
        public string  SchoolName   { get; set; } = string.Empty;
        public string  StudentName  { get; set; } = string.Empty;
        public string? AdmissionNo  { get; set; }
        public string? PhotoUrl     { get; set; }
        public string? ClassName    { get; set; }
        public string? Section      { get; set; }
        public string? RollNo       { get; set; }
        public string? ClassTeacher { get; set; }
        public string? AcademicYear { get; set; }
        public int     SectionId    { get; set; }   // current session's class-section (timetable)

        /// <summary>False for a child who passed out / left in the last 12 months:
        /// only receipts and results are shown then.</summary>
        public bool    IsCurrent    { get; set; }
        public string? LeftOn       { get; set; }

        // Screens the school shows to parents, and modules in the school's plan.
        public bool ShowFees      { get; set; }
        public bool ShowReceipts  { get; set; }
        public bool ShowResults   { get; set; }
        public bool ShowHomework  { get; set; }
        public bool ShowTimetable { get; set; }
        public bool ShowNotices   { get; set; }
        public bool FeesOn        { get; set; }
        public bool AttendanceOn  { get; set; }
        public bool ExamsOn       { get; set; }
        public bool AcademicsOn   { get; set; }
    }

    /// <summary>Answer of core.sp_parent_login_code: OK / INVALID / EXPIRED / LOCKED.</summary>
    public class ParentCodeResult
    {
        public string Status      { get; set; } = "INVALID";
        public int    WaitMinutes { get; set; }
        public bool   HasChildren { get; set; }
    }

    /// <summary>A mobile on a student's record, for Student profile > Parent access.</summary>
    public class ParentAccessMobile
    {
        public string  Label       { get; set; } = string.Empty;   // Mobile / Alternate mobile
        public string  Mobile      { get; set; } = string.Empty;
        public bool    IsBlocked   { get; set; }
        public string? LastLogin   { get; set; }
        public bool    ParentAppOn { get; set; }
    }

    public class ParentNotice
    {
        public int     Id       { get; set; }
        public string  Title    { get; set; } = string.Empty;
        public string? Body     { get; set; }
        public string? Category { get; set; }
        public bool    IsPinned { get; set; }
        public string? PostedOn { get; set; }
    }

    /// <summary>Students > Parent logins report.</summary>
    public class ParentLoginReport
    {
        public List<ParentLoginClassRow> Classes { get; set; } = new();
        public List<ParentLoginLogRow>   Log     { get; set; } = new();
        public List<ParentLoginNeverRow> Never   { get; set; } = new();
    }

    public class ParentLoginClassRow
    {
        public string ClassName { get; set; } = string.Empty;
        public string Section   { get; set; } = string.Empty;
        public int    Students  { get; set; }
        public int    LoggedIn  { get; set; }
    }

    public class ParentLoginLogRow
    {
        public string AtTime      { get; set; } = string.Empty;
        public string Mobile      { get; set; } = string.Empty;
        public string Action      { get; set; } = string.Empty;
        public string Detail      { get; set; } = string.Empty;
        public string StudentName { get; set; } = string.Empty;
        public string ClassName   { get; set; } = string.Empty;
        public string Section     { get; set; } = string.Empty;
    }

    public class ParentLoginNeverRow
    {
        public string StudentName { get; set; } = string.Empty;
        public string ClassName   { get; set; } = string.Empty;
        public string Section     { get; set; } = string.Empty;
        public string RollNo      { get; set; } = string.Empty;
    }
}
