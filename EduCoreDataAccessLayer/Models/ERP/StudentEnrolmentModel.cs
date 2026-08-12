namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One session in a student's timeline, from core.student_enrolment. The
    /// student row only holds where they are now, so this is the only place the
    /// classes they passed through are recorded.
    /// </summary>
    public class StudentEnrolmentItem
    {
        public string  AcademicYear { get; set; } = string.Empty;
        public string  ClassName    { get; set; } = string.Empty;
        public string? Section      { get; set; }
        public string? RollNo       { get; set; }
        /// <summary>Active | Promoted | Retained | PassedOut | Left</summary>
        public string  Status       { get; set; } = string.Empty;
        public bool    IsCurrent    { get; set; }
    }
}
