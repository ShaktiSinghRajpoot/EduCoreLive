using EduCoreDataAccessLayer.Models.ERP;

namespace educore.Models
{
    /// <summary>
    /// Drives the ID-card print sheet. One card per student, laid out in the chosen
    /// layout. Cards read live student data (not frozen) — reprint always reflects
    /// the current record. Shared by the bulk sheet, a single card and the preview.
    /// </summary>
    public class IdCardPrintModel
    {
        public List<IdCardStudent> Students { get; set; } = new();
        public SchoolManageModel   School   { get; set; } = new();

        /// <summary>Absolute logo URL — the print popup is about:blank with no base.</summary>
        public string? LogoUrl { get; set; }

        public string Format    { get; set; } = "Portrait";   // Portrait | Landscape
        public bool   IsPreview { get; set; }

        public bool IsLandscape => string.Equals(Format, "Landscape", StringComparison.OrdinalIgnoreCase);
    }
}
