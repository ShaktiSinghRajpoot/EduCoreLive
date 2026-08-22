namespace EduCoreDataAccessLayer.Models.ERP
{
    // An exam is SCHOOL-WIDE ("Unit Test 1" exists once per academic year). The
    // classes that sit it, and what each sits on which date, live on the datesheet.

    /// <summary>One exam on the "Exams this year" list.</summary>
    public class ExamListItem
    {
        public int    ExamId       { get; set; }
        public string ExamName     { get; set; } = string.Empty;
        public string ExamType     { get; set; } = string.Empty;   // lookup code, may be blank
        public string TypeLabel    { get; set; } = string.Empty;   // resolved label for display
        public string StartDate    { get; set; } = string.Empty;   // yyyy-MM-dd
        public string EndDate      { get; set; } = string.Empty;   // yyyy-MM-dd
        public int    ClassCount   { get; set; }
        public int    SubjectCount { get; set; }                   // across every class
        public string ClassNames   { get; set; } = string.Empty;   // "1st, 2nd, 3rd"
    }

    /// <summary>One subject on a class's datesheet.</summary>
    public class ExamSubjectRow
    {
        public int     SubjectId   { get; set; }
        public string  SubjectName { get; set; } = string.Empty;
        public string? ExamDate    { get; set; }                   // yyyy-MM-dd, null = not set
        public decimal MaxMarks    { get; set; } = 100;
        public decimal PassMarks   { get; set; } = 35;
    }

    /// <summary>One class's datesheet within an exam.</summary>
    public class ExamClassDatesheet
    {
        public int    AcademicClassId { get; set; }
        public string ClassName       { get; set; } = string.Empty;
        public List<ExamSubjectRow> Subjects { get; set; } = new();
    }

    /// <summary>An exam plus every class's datesheet — what the edit form loads.</summary>
    public class ExamDetail
    {
        public int    ExamId    { get; set; }
        public string ExamName  { get; set; } = string.Empty;
        public string ExamType  { get; set; } = string.Empty;
        public string StartDate { get; set; } = string.Empty;      // yyyy-MM-dd
        public string EndDate   { get; set; } = string.Empty;      // yyyy-MM-dd
        public List<ExamClassDatesheet> Classes { get; set; } = new();
    }

    /// <summary>The exam list plus the academic year it belongs to (one round trip).</summary>
    public class ExamListData
    {
        public int    AcademicYearId   { get; set; }
        public string AcademicYearName { get; set; } = string.Empty;
        public List<ExamListItem> Exams { get; set; } = new();
    }

    /// <summary>One datesheet row posted from the form.</summary>
    public class ExamSubjectInput
    {
        public int      SubjectId { get; set; }
        public string?  ExamDate  { get; set; }                    // yyyy-MM-dd
        public decimal? MaxMarks  { get; set; }
        public decimal? PassMarks { get; set; }
    }

    /// <summary>One class's datesheet posted from the form.</summary>
    public class ExamClassInput
    {
        public int ClassId { get; set; }
        public List<ExamSubjectInput> Subjects { get; set; } = new();
    }

    /// <summary>The Create/Edit Exam form's payload. ExamId 0 = create.</summary>
    public class ExamSaveRequest
    {
        public int     ExamId    { get; set; }
        public string? ExamName  { get; set; }
        public string? ExamType  { get; set; }                     // lookup code, optional
        public string? StartDate { get; set; }                     // yyyy-MM-dd
        public string? EndDate   { get; set; }                     // yyyy-MM-dd
        /// <summary>Every class sitting this exam. A class left out loses its datesheet.</summary>
        public List<ExamClassInput> Classes { get; set; } = new();
    }

    public class ExamSaveResult
    {
        public bool   Success      { get; set; }
        public int    ExamId       { get; set; }
        public int    ClassCount   { get; set; }
        public int    SubjectCount { get; set; }
        public string Message      { get; set; } = string.Empty;
    }

    // ── Datesheet view ──

    /// <summary>One paper on the datesheet: which class sits what, when.</summary>
    public class ExamDatesheetRow
    {
        public string? ExamDate        { get; set; }               // yyyy-MM-dd
        public int     AcademicClassId { get; set; }
        public string  ClassName       { get; set; } = string.Empty;
        public string  SubjectName     { get; set; } = string.Empty;
        public decimal MaxMarks        { get; set; }
        public decimal PassMarks       { get; set; }
        public int     ExamId          { get; set; }
        public string  ExamName        { get; set; } = string.Empty;
        public string  TypeLabel       { get; set; } = string.Empty;
    }

    public class ExamDatesheetData
    {
        public string AcademicYearName { get; set; } = string.Empty;
        public List<ExamDatesheetRow> Rows { get; set; } = new();
    }

    // ── Marks Entry ──
    // A SHEET is one (exam, class, section, subject) — what a teacher fills in one
    // sitting. The class is part of the key: section 'A' exists in every class.

    /// <summary>A class that sits a given exam — the Class dropdown.</summary>
    public class ExamClassOption
    {
        public int    AcademicClassId { get; set; }
        public string ClassName       { get; set; } = string.Empty;
        public int    SubjectCount    { get; set; }
    }

    /// <summary>A subject on the class's datesheet, with the scale its sheet is marked against.</summary>
    public class ExamSheetSubject
    {
        public int     SubjectId   { get; set; }
        public string  SubjectName { get; set; } = string.Empty;
        public string? ExamDate    { get; set; }                   // yyyy-MM-dd
        public decimal MaxMarks    { get; set; } = 100;
        public decimal PassMarks   { get; set; } = 35;
    }

    /// <summary>A section of the class that actually has students enrolled.</summary>
    public class ExamSheetSection
    {
        public string Section      { get; set; } = string.Empty;
        public int    StudentCount { get; set; }
    }

    /// <summary>What the Marks Entry selectors need once exam + class are picked.</summary>
    public class ExamSheetSetup
    {
        public List<ExamSheetSubject> Subjects { get; set; } = new();
        public List<ExamSheetSection> Sections { get; set; } = new();
    }

    /// <summary>One student on a marks sheet.</summary>
    public class ExamMarkRow
    {
        public int      StudentId   { get; set; }
        public string   RollNo      { get; set; } = string.Empty;
        public string   StudentName { get; set; } = string.Empty;
        public string   Gender      { get; set; } = string.Empty;
        public decimal? Marks       { get; set; }                  // null = not entered, or absent
        public bool     IsAbsent    { get; set; }
        public bool     HasMark     { get; set; }                  // a row already exists
    }

    /// <summary>One sheet: its scale, its lock state, and its roster.</summary>
    public class ExamSheet
    {
        public decimal MaxMarks    { get; set; } = 100;
        public decimal PassMarks   { get; set; } = 35;
        public string? ExamDate    { get; set; }                   // yyyy-MM-dd
        public string  SubjectName { get; set; } = string.Empty;
        public bool    IsFinalized { get; set; }
        public string? FinalizedAt { get; set; }                   // yyyy-MM-dd
        public List<ExamMarkRow> Students { get; set; } = new();
    }

    /// <summary>One mark posted from the grid. Absent wins: it clears the marks.</summary>
    public class ExamMarkInput
    {
        public int      StudentId { get; set; }
        public decimal? Marks     { get; set; }
        public bool     Absent    { get; set; }
    }

    public class ExamMarksSaveRequest
    {
        public int     ExamId          { get; set; }
        public int     AcademicClassId { get; set; }
        public int     SubjectId       { get; set; }
        public string? Section         { get; set; }
        /// <summary>True = finalize and lock; unmarked students are recorded Absent.</summary>
        public bool    Finalize        { get; set; }
        public List<ExamMarkInput> Items { get; set; } = new();
    }

    public class ExamMarksSaveResult
    {
        public bool   Success      { get; set; }
        public int    Saved        { get; set; }
        public int    MarkedAbsent { get; set; }
        public bool   IsFinalized  { get; set; }
        public string Message      { get; set; } = string.Empty;
    }
}
