namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One class-section row on the Assign Class Teacher grid.</summary>
    public class ClassTeacherSection
    {
        public int     SectionId    { get; set; }
        public string  ClassName    { get; set; } = string.Empty;
        public int     ClassRank    { get; set; }
        public string  SectionName  { get; set; } = string.Empty;
        public string? RoomNo       { get; set; }
        public int?    TeacherId    { get; set; }   // staff_id, null = unassigned
        public string? TeacherName  { get; set; }
        public int     TeacherLoad  { get; set; }   // sections this teacher owns (>1 = conflict)
    }

    /// <summary>A teacher who can be assigned as a class teacher.</summary>
    public class ClassTeacherOption
    {
        public int    StaffId  { get; set; }
        public string FullName { get; set; } = string.Empty;
    }
    /// <summary>A section someone is the class teacher of, this session.</summary>
    public class MyClassSection
    {
        public int    SectionId    { get; set; }
        public string ClassName    { get; set; } = string.Empty;
        public string SectionName  { get; set; } = string.Empty;
        public string SessionName  { get; set; } = string.Empty;
        public int    Students     { get; set; }
        public bool   MarkedToday  { get; set; }   // today's attendance already taken

        /// <summary>e.g. "Class 3-A": the class name as stored, plus the section.</summary>
        public string Label => ClassName + (string.IsNullOrWhiteSpace(SectionName) ? "" : "-" + SectionName);
    }
}
