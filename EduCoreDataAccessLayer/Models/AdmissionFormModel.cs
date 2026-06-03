using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace EduCoreDataAccessLayer.Models
{
    // ── Form binding model for the admission modal ───────────────
    public class AdmissionFormModel
    {
        public string? AdmissionNo { get; set; }
        public string? RollNo { get; set; }
        public string? StudentName { get; set; }
        public string? Gender { get; set; }
        public DateOnly? DateOfBirth { get; set; }
        public string? ClassName { get; set; }
        public string? Section { get; set; }
        public string? AcademicYear { get; set; }
        public DateOnly? AdmissionDate { get; set; }
        public string? GuardianName { get; set; }
        public string? MotherName { get; set; }
        public string? MobileNumber { get; set; }
        public string? AlternateMobile { get; set; }
        public string? Address { get; set; }
        public string? DiscountType { get; set; }
        public string? DiscountReason { get; set; }
        public string? LedgerPreviewJson { get; set; }
        public int? EnquiryId { get; set; }
    }
}
