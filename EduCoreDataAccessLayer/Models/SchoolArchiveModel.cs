namespace educore.Models
{
    /// <summary>
    /// A school's complete data set, produced by core.sp_school_archive before a purge.
    /// Written to disk by SchoolsController so the deletion is recoverable — the purge
    /// itself has no undo.
    /// </summary>
    public class SchoolArchiveModel
    {
        public int SchoolId { get; set; }
        public string? SchoolCode { get; set; }
        public string? SchoolName { get; set; }

        /// <summary>Total rows captured across every school-scoped table.</summary>
        public long TotalRows { get; set; }

        /// <summary>Pretty-printed JSON of every table that had rows for this school.</summary>
        public string ArchiveJson { get; set; } = "{}";

        /// <summary>Safe, timestamped file name, e.g. "SCH14_2026-07-26_143022.json".</summary>
        public string FileName =>
            $"{(string.IsNullOrWhiteSpace(SchoolCode) ? "school-" + SchoolId : SchoolCode)}" +
            $"_{DateTime.Now:yyyy-MM-dd_HHmmss}.json";
    }
}
