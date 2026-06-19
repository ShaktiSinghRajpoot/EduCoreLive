namespace EduCoreDataAccessLayer.Models.Admin
{
    // ── A single fee head, frozen into the student's plan at admission ──
    public class StudentFeePlanItem
    {
        public int?     FeeHeadId   { get; set; }
        public string   FeeHeadName { get; set; } = string.Empty;
        public string   Frequency   { get; set; } = "Yearly";   // One Time | Monthly | Yearly
        public decimal  Amount      { get; set; }
        public bool     IsOptional  { get; set; }
    }

    // ── Full admission record (form submit + persistence) ───────────────
    public class AdmissionModel
    {
        public int       StudentId        { get; set; }
        public int       TenantId         { get; set; }
        public int       SchoolId         { get; set; }
        // Identity / placement
        public string?   AdmissionNo      { get; set; }   // blank => auto-generated
        public string?   RollNo           { get; set; }
        public string    StudentName      { get; set; } = string.Empty;
        public string?   Gender           { get; set; }
        public DateOnly? DateOfBirth      { get; set; }
        public string    ClassName        { get; set; } = string.Empty;
        public string?   Section          { get; set; }
        public string    AcademicYear     { get; set; } = string.Empty;
        public DateOnly? AdmissionDate    { get; set; }
        // Parent / contact
        public string?   GuardianName     { get; set; }
        public string?   MotherName       { get; set; }
        public string?   MobileNumber     { get; set; }
        public string?   AlternateMobile  { get; set; }
        public string?   Address          { get; set; }
        // Identity / demographics
        public string?   BloodGroup       { get; set; }
        public string?   Religion         { get; set; }
        public string?   Category         { get; set; }   // General/OBC/SC/ST/EWS
        public string?   Nationality      { get; set; }
        public string?   MotherTongue     { get; set; }
        public string?   IdProofNo        { get; set; }   // Aadhaar / birth-cert no
        public string?   ApaarId          { get; set; }   // APAAR / "One Nation One Student ID" (12-digit)
        public string?   UdiseStudentId   { get; set; }   // UDISE+ PEN (Permanent Education Number)
        // Previous school (transfers)
        public string?   PrevSchoolName   { get; set; }
        public string?   PrevBoard        { get; set; }
        public string?   PrevClass        { get; set; }
        public string?   PrevTcNo         { get; set; }
        // Parent details (full)
        public string?   FatherOccupation     { get; set; }
        public string?   FatherQualification  { get; set; }
        public string?   FatherEmail          { get; set; }
        public string?   MotherOccupation     { get; set; }
        public string?   MotherQualification  { get; set; }
        public string?   MotherEmail          { get; set; }
        public decimal?  AnnualIncome         { get; set; }
        // Documents checklist (JSON array of {name,status})
        public string?   DocumentsJson    { get; set; }
        // Fee snapshot totals
        public decimal   PayTodayTotal    { get; set; }
        public decimal   MonthlyTotal     { get; set; }
        public decimal   YearlyTotal      { get; set; }
        public decimal   AnnualTotal      { get; set; }
        // Concession
        public string?   ConcessionType   { get; set; }
        public decimal   ConcessionValue  { get; set; }
        public decimal   ConcessionAmount { get; set; }
        public string?   ConcessionReason { get; set; }
        // Fee plan (frozen heads)
        public List<StudentFeePlanItem> FeePlan { get; set; } = new();
        // Conversion linkage
        public int?      EnquiryId        { get; set; }
    }

    // ── Save result returned to the controller ─────────────────────────
    public class AdmissionSaveResult
    {
        public int    StudentId   { get; set; }
        public bool   Success     { get; set; }
        public string Message     { get; set; } = string.Empty;
        public string? AdmissionNo { get; set; }
    }

    // ── List/grid row ───────────────────────────────────────────────────
    public class StudentListModel
    {
        public int       StudentId      { get; set; }
        public string    AdmissionNo    { get; set; } = string.Empty;
        public string?   RollNo         { get; set; }
        public string    StudentName    { get; set; } = string.Empty;
        public string?   Gender         { get; set; }
        public string    ClassName      { get; set; } = string.Empty;
        public string?   Section        { get; set; }
        public string    AcademicYear   { get; set; } = string.Empty;
        public DateOnly? AdmissionDate  { get; set; }
        public string?   GuardianName   { get; set; }
        public string?   Mobile         { get; set; }
        public decimal   AnnualTotal    { get; set; }
        public string    Status         { get; set; } = "Active";
        public string    ApprovalStatus { get; set; } = "Approved";
        public string    FeeStatus      { get; set; } = "Pending";
        public decimal   FeeDue         { get; set; }
        public int?      EnquiryId      { get; set; }
    }
}
