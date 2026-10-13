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
