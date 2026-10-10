namespace EduCoreDataAccessLayer.Models.ERP
{
    // ── Grade scale ──
    // A band runs from its min % up to the next band's min %; the max % is what
    // the school sees ("81-90"). See exam_results_publish.sql.

    public class GradeBand
    {
        public string   Label      { get; set; } = string.Empty;
        public decimal  MinPercent { get; set; }
        public decimal  MaxPercent { get; set; }
        public decimal? GradePoint { get; set; }
        public string?  Remark     { get; set; }
    }

    public class GradeScale
    {
        public List<GradeBand> Bands { get; set; } = new();
        /// <summary>True when the school has not saved its own scale (CBSE default).</summary>
        public bool IsDefault { get; set; }
    }

    public class GradeScaleSaveRequest
    {
        public List<GradeBand> Bands { get; set; } = new();
    }

    public class ExamResultActionResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
    }

    // ── Result publishing ──

    /// <summary>An exam's result status: published or not, what blocks it, and its log.</summary>
    public class ExamResultStatus
    {
        public int     ExamId        { get; set; }
        public string  ExamName      { get; set; } = string.Empty;
        public string  Status        { get; set; } = string.Empty;   // the datesheet
        public string  ResultsStatus { get; set; } = string.Empty;   // Unpublished | Published
        public string? PublishedAt   { get; set; }
        public string? PublishedBy   { get; set; }
        public int     SheetCount    { get; set; }
        public int     PendingCount  { get; set; }
        public List<ExamPendingSheet>  Pending { get; set; } = new();
        public List<ExamResultLogRow>  Log     { get; set; } = new();
    }

    /// <summary>A mark sheet that is not finalised yet.</summary>
    public class ExamPendingSheet
    {
        public int    AcademicClassId { get; set; }
        public string ClassName       { get; set; } = string.Empty;
        public string Section         { get; set; } = string.Empty;
        public string SubjectName     { get; set; } = string.Empty;
    }

    public class ExamResultLogRow
    {
        public string Action { get; set; } = string.Empty;   // Publish | Unpublish
        public string Reason { get; set; } = string.Empty;
        public string DoneBy { get; set; } = string.Empty;
        public string DoneAt { get; set; } = string.Empty;
    }

    // ── Class result sheet: students x subjects ──

    public class ClassResultSheet
    {
        public string  ExamName         { get; set; } = string.Empty;
        public string  ClassName        { get; set; } = string.Empty;
        public string  Section          { get; set; } = string.Empty;
        public string  Status           { get; set; } = string.Empty;
        public string  ResultsStatus    { get; set; } = string.Empty;
        public string? PublishedAt      { get; set; }
        public string  AcademicYearName { get; set; } = string.Empty;
        /// <summary>This class's mark sheets not finalised yet (the sheet is provisional).</summary>
        public int     PendingCount     { get; set; }
        public List<ClassResultSubject> Subjects { get; set; } = new();
        public List<ClassResultStudent> Students { get; set; } = new();
    }

    public class ClassResultSubject
    {
        public int     SubjectId   { get; set; }
        public string  SubjectName { get; set; } = string.Empty;
        public decimal MaxMarks    { get; set; }
        public decimal PassMarks   { get; set; }
    }

    public class ClassResultStudent
    {
        public int      StudentId    { get; set; }
        public string   RollNo       { get; set; } = string.Empty;
        public string   AdmissionNo  { get; set; } = string.Empty;
        public string   StudentName  { get; set; } = string.Empty;
        public string   Section      { get; set; } = string.Empty;
        public decimal  Obtained     { get; set; }
        public decimal  Total        { get; set; }
        public decimal? Percent      { get; set; }   // null = absent from every paper
        public string?  Grade        { get; set; }
        public int      AbsentCount  { get; set; }
        public int      FailedCount  { get; set; }
        public int?     ClassRank    { get; set; }
        public int?     SectionRank  { get; set; }
        public int      ClassSize    { get; set; }
        public int      SectionSize  { get; set; }
        public List<ClassResultCell> Cells { get; set; } = new();
    }

    public class ClassResultCell
    {
        public int      SubjectId { get; set; }
        public decimal? Marks     { get; set; }   // null = absent or not entered
        public bool     IsAbsent  { get; set; }
        public string?  Grade     { get; set; }
        public bool?    Passed    { get; set; }
    }
}
