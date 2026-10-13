namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One piece of homework (academic.sp_homework_manage).</summary>
    public class Homework
    {
        public int     Id           { get; set; }
        public int     SectionId    { get; set; }
        public string  SectionLabel { get; set; } = string.Empty;
        public int     SubjectId    { get; set; }
        public string  SubjectName  { get; set; } = string.Empty;
        public string? TeacherName  { get; set; }
        public string  Title        { get; set; } = string.Empty;
        public string? Details      { get; set; }
        /// <summary>yyyy-MM-dd</summary>
        public string  AssignedOn   { get; set; } = string.Empty;
        /// <summary>yyyy-MM-dd</summary>
        public string  DueOn        { get; set; } = string.Empty;
        public bool    CanEdit      { get; set; }
        public int     DoneCount    { get; set; }
        public int     NotDoneCount { get; set; }
        public int     StudentCount { get; set; }
        /// <summary>Student view only: Done | NotDone | Late, or null when not checked.</summary>
        public string? MyStatus     { get; set; }
    }

    /// <summary>Homework page › Overview (academic.sp_homework_overview).</summary>
    public class HomeworkOverview
    {
        public List<HomeworkOverviewRow> Teachers { get; set; } = new();
        public List<HomeworkOverviewRow> Classes  { get; set; } = new();
        public List<HomeworkOverviewRow> Subjects { get; set; } = new();
    }

    /// <summary>
    /// One teacher, class or subject on the overview. Expected = homework x students of
    /// its section; Recorded = students the teacher marked; Done = marked Done or Late.
    /// </summary>
    public class HomeworkOverviewRow
    {
        public int     Id          { get; set; }             // staff id (teachers)
        public string  Name        { get; set; } = string.Empty;
        public int     Sections    { get; set; }             // taught (teachers) / in the class (classes)
        public int     Periods     { get; set; }             // teachers: periods a week
        public int     Covered     { get; set; }             // teachers: sections given homework
        public int     Students    { get; set; }             // classes
        public int     Sets        { get; set; }
        public int     CheckedSets { get; set; }
        public int     Expected    { get; set; }
        public int     Recorded    { get; set; }
        public int     Done        { get; set; }
        public string? LastGiven   { get; set; }             // teachers, yyyy-MM-dd
    }

    /// <summary>A student on the "who did it" sheet.</summary>
    public class HomeworkStudent
    {
        public int     StudentId   { get; set; }
        public string  StudentName { get; set; } = string.Empty;
        public string? RollNo      { get; set; }
        public string? AdmissionNo { get; set; }
        public string? Status      { get; set; }
    }
}
