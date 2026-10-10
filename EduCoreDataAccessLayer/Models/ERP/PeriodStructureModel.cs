namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>One entry in the daily bell schedule.</summary>
    public class PeriodStructureItem
    {
        public int    PeriodId   { get; set; }
        public int    Seq        { get; set; }
        public string PeriodType { get; set; } = "class";   // class | assembly | break | lunch | diary
        public string Label      { get; set; } = string.Empty;
        public string StartTime  { get; set; } = string.Empty;  // HH:mm
        public string EndTime    { get; set; } = string.Empty;  // HH:mm
        public int?   DayOfWeek  { get; set; }                   // null = default schedule, 0 = Sunday … 6 = Saturday
    }

    public class PeriodStructureSaveResult
    {
        public bool   Success { get; set; }
        public string Message { get; set; } = string.Empty;
    }
}
