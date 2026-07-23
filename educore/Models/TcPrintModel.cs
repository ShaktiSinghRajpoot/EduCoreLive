using EduCoreDataAccessLayer.Models.ERP;

namespace educore.Models
{
    /// <summary>
    /// Drives the TC print page. The same view renders a real certificate (from the
    /// frozen register) and a format preview (sample data) — IsPreview tells them
    /// apart: a preview is not auto-printed and never stamps DUPLICATE.
    /// </summary>
    public class TcPrintModel
    {
        public TransferCertificate Tc     { get; set; } = new();
        public SchoolManageModel   School { get; set; } = new();

        /// <summary>Absolute logo URL — the print popup is about:blank with no base.</summary>
        public string? LogoUrl { get; set; }

        public bool IsPreview { get; set; }

        public string Format => Tc.Format;
        public bool   ShowDuplicate => !IsPreview && Tc.WasDuplicate;
    }
}
