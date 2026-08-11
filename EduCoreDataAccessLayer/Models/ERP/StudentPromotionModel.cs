namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One bulk promotion run, as posted from Student/Promotion. The target class
    /// is deliberately absent: the proc derives it from the school's class ladder
    /// so a stale page cannot move students into the wrong class.
    /// </summary>
    public class StudentPromotionRequest
    {
        public string  SourceYear    { get; set; } = string.Empty;
        public string  TargetYear    { get; set; } = string.Empty;
        /// <summary>Section in the new class, or "keep" to leave each student's section alone.</summary>
        public string? TargetSection { get; set; }
        public bool    CarryDues     { get; set; } = true;
        public List<StudentPromotionItem> Students { get; set; } = new();
    }

    public class StudentPromotionItem
    {
        public int    StudentId { get; set; }
        /// <summary>promote | retain | passout</summary>
        public string Outcome   { get; set; } = string.Empty;
    }

    public class StudentPromotionResult
    {
        public bool    Success       { get; set; }
        public string  Message       { get; set; } = string.Empty;
        public int     Promoted      { get; set; }
        public int     Retained      { get; set; }
        public int     PassedOut     { get; set; }
        public int     Skipped       { get; set; }
        /// <summary>Names + reasons for anyone the proc could not move ("Devi Sen (pending dues)").</summary>
        public string? SkippedDetail { get; set; }
    }
}
