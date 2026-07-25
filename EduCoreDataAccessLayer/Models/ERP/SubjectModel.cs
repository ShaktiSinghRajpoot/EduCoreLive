namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>A class in the left panel of Subject Management, with its subject count.</summary>
    public class SubjectClassItem
    {
        public int     AcademicClassId { get; set; }
        public string  ClassName       { get; set; } = string.Empty;
        public string? Stream          { get; set; }
        public int     DisplayOrder    { get; set; }
        public int     SubjectCount    { get; set; }
    }

    /// <summary>One subject from the school's master list.</summary>
    public class SubjectItem
    {
        public int    SubjectId   { get; set; }
        public string SubjectName { get; set; } = string.Empty;
    }

    public class SubjectSaveResult
    {
        public bool   Success      { get; set; }
        public int    SubjectCount { get; set; }
        public string Message      { get; set; } = string.Empty;
    }
}
