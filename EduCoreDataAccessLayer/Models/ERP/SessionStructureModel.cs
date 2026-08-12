namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// Whether one academic session has its classes and sections yet. Classes are
    /// per-session rows, so a newly created session starts empty and nothing that
    /// depends on a class works in it until the structure is copied forward.
    /// </summary>
    public class SessionStructureInfo
    {
        public int    AcademicYearId   { get; set; }
        public string AcademicYearName { get; set; } = string.Empty;
        public int    ClassCount       { get; set; }
        public int    SectionCount     { get; set; }

        /// <summary>Closest earlier session that has classes — what "copy setup" would copy from. 0 when there is none.</summary>
        public int    SourceYearId     { get; set; }
        public string SourceYearName   { get; set; } = string.Empty;

        public bool IsReady => ClassCount > 0 && SectionCount > 0;
        public bool CanCopy => SourceYearId > 0;
    }

    public class SessionCloneResult
    {
        public bool   Success        { get; set; }
        public string Message        { get; set; } = string.Empty;
        public int    ClassesCopied  { get; set; }
        public int    SectionsCopied { get; set; }
    }
}
