namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One student's attendance for a session, plus the day marks for one month.
    /// Follows the register's conventions: a "school day" is a day a register was actually
    /// taken for that class, Sundays excluded, Late counts as present.</summary>
    public class StudentAttendanceSummary
    {
        public int     SchoolDays { get; set; }
        public int     Present    { get; set; }
        public int     Absent     { get; set; }
        public int     LeaveDays  { get; set; }
        public decimal Percent    { get; set; }

        public List<StudentAttendanceMonth> Months { get; set; } = new();

        /// <summary>Day number → mark (P / A / L) for the requested month. A day with no
        /// entry is a day no register was taken, not an absence.</summary>
        public Dictionary<int, string> Days { get; set; } = new();
    }

    public class StudentAttendanceMonth
    {
        public int Month      { get; set; }
        public int Year       { get; set; }
        public int SchoolDays { get; set; }
        public int Present    { get; set; }
    }
}
