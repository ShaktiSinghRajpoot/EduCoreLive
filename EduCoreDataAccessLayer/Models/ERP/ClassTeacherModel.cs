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
}
