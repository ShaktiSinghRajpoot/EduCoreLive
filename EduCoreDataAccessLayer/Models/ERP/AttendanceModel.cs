namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One student on the daily attendance roster.</summary>
    public class AttendanceStudent
    {
        public int     StudentId    { get; set; }
        public string? RollNo       { get; set; }
        public string? AdmissionNo  { get; set; }
        public string  StudentName  { get; set; } = string.Empty;
        public string? GuardianName { get; set; }   // parent — for the absentee WhatsApp notice
        public string? Mobile       { get; set; }

        /// <summary>Present | Absent | Late | Leave. Null when the day is not yet marked.</summary>
        public string? Status      { get; set; }
        public string? Remarks     { get; set; }
        public bool    IsMarked    { get; set; }
    }

    /// <summary>One mark posted from the roster.</summary>
    public class AttendanceMark
    {
        public int     StudentId { get; set; }
        public string  Status    { get; set; } = "Present";
        public string? Remarks   { get; set; }
    }

    /// <summary>The whole class's marks for a date.</summary>
    public class AttendanceSaveRequest
    {
        public string?               Date    { get; set; }   // yyyy-MM-dd
        public string?               Class   { get; set; }   // for the class-teacher gate
        public string?               Section { get; set; }
        public List<AttendanceMark>  Items   { get; set; } = new();
    }

    public class AttendanceSaveResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
        public int    Saved   { get; set; }
    }
}
