using EduCoreDataAccessLayer.Helpers;

namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>A Bonafide or Character certificate (core.certificates), frozen at issue time.</summary>
    public class Certificate
    {
        public int     CertId        { get; set; }
        public string  CertNo        { get; set; } = string.Empty;
        /// <summary>Bonafide | Character</summary>
        public string  CertType      { get; set; } = string.Empty;
        public int     StudentId     { get; set; }
        public string  StudentName   { get; set; } = string.Empty;
        public string? Gender        { get; set; }
        public string? FatherName    { get; set; }
        public string? MotherName    { get; set; }
        public string? Dob           { get; set; }
        public string? AdmissionNo   { get; set; }
        public string? AdmissionDate { get; set; }
        public string? ClassName     { get; set; }
        public string? Section       { get; set; }
        public string? AcademicYear  { get; set; }
        public bool    IsCurrent     { get; set; }
        public string? DateOfLeaving { get; set; }
        public string? Purpose       { get; set; }
        public string? Conduct       { get; set; }
        public string? Remarks       { get; set; }
        public string  IssueDate     { get; set; } = string.Empty;
        public bool    IsVoid        { get; set; }
        public string? VoidReason    { get; set; }

        public bool   IsGirl  => string.Equals(Gender, "Female", StringComparison.OrdinalIgnoreCase);
        /// <summary>"son" / "daughter" for the certificate text.</summary>
        public string Child   => IsGirl ? "daughter" : "son";
        public string HeShe   => IsGirl ? "She" : "He";
        public string HisHer  => IsGirl ? "her" : "his";
        public string HisHerCap => IsGirl ? "Her" : "His";
        public string ClassDisplay => string.IsNullOrWhiteSpace(Section) ? (ClassName ?? "") : $"{ClassName} – {Section}";
        public string DobDisplay   => Dates.Show(Dob);
    }

    /// <summary>A search hit when picking the student for a certificate.</summary>
    public class CertificateStudentHit
    {
        public int     StudentId    { get; set; }
        public string  StudentName  { get; set; } = string.Empty;
        public string? AdmissionNo  { get; set; }
        public string? ClassName    { get; set; }
        public string? Section      { get; set; }
        public string? GuardianName { get; set; }
        public string? Mobile       { get; set; }
        public bool    IsCurrent    { get; set; }
        public string? Status       { get; set; }
    }

    /// <summary>What a report card needs beyond the exam result: mother's name and attendance.</summary>
    public class ReportCardExtra
    {
        public int      StudentId  { get; set; }
        public string?  MotherName { get; set; }
        public int      SchoolDays { get; set; }
        public int      Present    { get; set; }
        public decimal? Percent    { get; set; }
    }
}
