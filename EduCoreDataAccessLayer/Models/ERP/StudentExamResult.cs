namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One student's result for one exam whose RESULTS are published.
    /// Absent subjects are reported but left out of the totals — not sitting a paper
    /// is a different fact from scoring zero on it.</summary>
    public class StudentExamResult
    {
        public List<StudentExamOption>  Exams    { get; set; } = new();
        public List<StudentExamSubject> Subjects { get; set; } = new();

        public int     SubjectCount { get; set; }   // counted subjects (absences excluded)
        public decimal Obtained     { get; set; }
        public decimal Total        { get; set; }
        public decimal Percent      { get; set; }
        public int     AbsentCount  { get; set; }
        public int     FailedCount  { get; set; }

        // From the school's grade scale and the class result (exam_results_publish.sql).
        // Null when the student was absent from every paper.
        public string? Grade        { get; set; }
        public int?    ClassRank    { get; set; }
        public int     ClassSize    { get; set; }
        public int?    SectionRank  { get; set; }
        public int     SectionSize  { get; set; }
    }

    /// <summary>A published exam this student has marks in.</summary>
    public class StudentExamOption
    {
        public int       ExamId    { get; set; }
        public string    ExamName  { get; set; } = string.Empty;
        public string?   ExamType  { get; set; }
        public string? StartDate { get; set; }
    }

    public class StudentExamSubject
    {
        public string   Subject   { get; set; } = string.Empty;
        public decimal? Obtained  { get; set; }   // null when absent
        public decimal? MaxMarks  { get; set; }
        public decimal? PassMarks { get; set; }
        public bool     IsAbsent  { get; set; }
        public bool?    Passed    { get; set; }   // null when absent, or no pass mark set
        public decimal? Percent   { get; set; }
        public string?  Grade     { get; set; }   // null when absent
    }
}
