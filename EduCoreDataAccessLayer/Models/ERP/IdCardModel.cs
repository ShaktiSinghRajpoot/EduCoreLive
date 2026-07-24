namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One student on an ID-card sheet. Read live from the student row (an ID card
    /// is not a frozen document), so it always reflects the current record.
    /// </summary>
    public class IdCardStudent
    {
        public int      StudentId    { get; set; }
        public string?  AdmissionNo  { get; set; }
        public string?  RollNo       { get; set; }
        public string   StudentName  { get; set; } = string.Empty;
        public string?  ClassName    { get; set; }
        public string?  Section      { get; set; }
        public string?  AcademicYear { get; set; }
        public DateOnly? Dob         { get; set; }
        public string?  BloodGroup   { get; set; }
        public string?  Gender       { get; set; }
        public string?  GuardianName { get; set; }
        public string?  Mobile       { get; set; }
        public string?  Address      { get; set; }
        public string?  PhotoUrl     { get; set; }

        public string ClassDisplay =>
            string.IsNullOrWhiteSpace(Section) ? (ClassName ?? "—") : $"{ClassName} - {Section}";
        public string DobDisplay => Dob?.ToString("dd MMM yyyy") ?? "—";
    }
}
