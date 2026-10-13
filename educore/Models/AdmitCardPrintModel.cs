using EduCoreDataAccessLayer.Models.ERP;

namespace educore.Models
{
    /// <summary>
    /// Drives the admit-card print sheet: one card per student with the exam's
    /// datesheet for their class. Built live from the student records and the
    /// datesheet, like the ID cards; nothing is stored.
    /// </summary>
    public class AdmitCardPrintModel
    {
        public List<IdCardStudent>    Students { get; set; } = new();
        public List<ExamDatesheetRow> Papers   { get; set; } = new();
        public SchoolManageModel      School   { get; set; } = new();

        /// <summary>Absolute logo URL, same as the ID card sheet.</summary>
        public string? LogoUrl { get; set; }

        public string ExamName    { get; set; } = string.Empty;
        public string SessionName { get; set; } = string.Empty;

        public string Format { get; set; } = "Classic";   // Classic | Compact | FullPage

        /// <summary>
        /// The papers one student sits: a paper with no section list is for the
        /// whole class; otherwise only the sections it names.
        /// </summary>
        public List<ExamDatesheetRow> PapersFor(IdCardStudent s)
        {
            var sec = (s.Section ?? "").Trim();
            return Papers
                .Where(p => string.IsNullOrWhiteSpace(p.SectionList)
                         || p.SectionList.Split(',').Any(x => string.Equals(x.Trim(), sec, StringComparison.OrdinalIgnoreCase)))
                .OrderBy(p => p.ExamDate).ThenBy(p => p.StartTime)
                .ToList();
        }
    }
}
