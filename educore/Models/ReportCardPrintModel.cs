using EduCoreDataAccessLayer.Models.ERP;

namespace educore.Models
{
    /// <summary>
    /// Drives the report-card print sheet: one A4 page per student, built from the
    /// published class result (marks, totals, grade, rank), the student records
    /// (father, DOB, photo) and the session's attendance. Nothing is stored.
    /// </summary>
    public class ReportCardPrintModel
    {
        public ClassResultSheet Sheet  { get; set; } = new();
        public SchoolManageModel School { get; set; } = new();
        public string? LogoUrl { get; set; }

        /// <summary>Student records by student id (father, DOB, photo).</summary>
        public Dictionary<int, IdCardStudent> Records { get; set; } = new();
        /// <summary>Mother's name and attendance by student id.</summary>
        public Dictionary<int, ReportCardExtra> Extras { get; set; } = new();
        /// <summary>The grade scale's remark for each grade label (e.g. "A1" -> "Outstanding").</summary>
        public Dictionary<string, string> GradeRemarks { get; set; } = new(StringComparer.OrdinalIgnoreCase);

        public static string Num(decimal? n) => n == null ? "—" : n.Value.ToString(n.Value % 1 == 0 ? "0" : "0.##");
    }
}
