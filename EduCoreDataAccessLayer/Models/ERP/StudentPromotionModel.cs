namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One bulk promotion run, as posted from Student/Promotion. The target class
    /// is deliberately absent: the proc derives it from the school's class ladder
    /// so a stale page cannot move students into the wrong class.
    /// </summary>
    /// <summary>One rung of a session's class ladder. Order is the class's
    /// display_order in THAT session — the promotion proc compares orders across
    /// the two sessions, so the name on its own is not enough.</summary>
    public class ClassLadderItem
    {
        public string Name  { get; set; } = string.Empty;
        public int    Order { get; set; }
    }

    public class StudentPromotionRequest
    {
        public string  SourceYear    { get; set; } = string.Empty;
        public string  TargetYear    { get; set; } = string.Empty;
        /// <summary>Section in the new class, or "keep" to leave each student's section alone.</summary>
        public string? TargetSection { get; set; }
        /// <summary>Despite the name (kept to match the proc's p_carry_dues), this does
        /// NOT move any money: the fee ledger is not year-scoped, so dues follow the
        /// student either way. False means "hold back anyone who still owes" — those
        /// students are skipped, not promoted.</summary>
        public bool    CarryDues     { get; set; } = true;
        public List<StudentPromotionItem> Students { get; set; } = new();
    }

    public class StudentPromotionItem
    {
        public int    StudentId { get; set; }
        /// <summary>promote | retain | passout</summary>
        public string Outcome   { get; set; } = string.Empty;

        /// <summary>Optional: send this student to a specific class instead of the next
        /// rung (a double promotion, 1st → 3rd). Null means "next class up". Only read
        /// for Outcome = promote; the proc still requires the class to exist in the
        /// target session and to be ABOVE the student's current one.</summary>
        public string? ToClass  { get; set; }
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
