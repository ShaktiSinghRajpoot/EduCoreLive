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
        // ── Identity / demographics ──
        public string? BloodGroup { get; set; }
        public string? Religion { get; set; }
        public string? Category { get; set; }
        public string? Nationality { get; set; }
        public string? MotherTongue { get; set; }
        public string? IdProofNo { get; set; }
        // ── Government identifiers (all optional — see Aadhaar/RTE note) ──
        public string? ApaarId { get; set; }
        public string? UdiseStudentId { get; set; }
        // ── Previous school (transfers) ──
        public string? PrevSchoolName { get; set; }
        public string? PrevBoard { get; set; }
        public string? PrevClass { get; set; }
        public string? PrevTcNo { get; set; }
        // ── Parent details (full) ──
        public string? FatherOccupation { get; set; }
        public string? FatherQualification { get; set; }
        public string? FatherEmail { get; set; }
        public string? MotherOccupation { get; set; }
        public string? MotherQualification { get; set; }
        public string? MotherEmail { get; set; }
        public decimal? AnnualIncome { get; set; }
        // ── Documents checklist (JSON array of {name,status}) ──
        public string? DocumentsJson { get; set; }
        public string? DiscountType { get; set; }
        public string? DiscountReason { get; set; }
        public string? LedgerPreviewJson { get; set; }
        public int? EnquiryId { get; set; }

        // ── Collect fee at admission (only when the school enables it) ──
        public bool     CollectFeeNow   { get; set; }
        public decimal? PaymentAmount   { get; set; }
        public string?  PaymentMode     { get; set; }
        public string?  PaymentReference { get; set; }
        public string?  PaymentRemarks  { get; set; }

        // ── Transport (optional): assign a route+stop at admission ──
        public int? TransportRouteId { get; set; }
        public int? TransportStopId  { get; set; }
    }
}
