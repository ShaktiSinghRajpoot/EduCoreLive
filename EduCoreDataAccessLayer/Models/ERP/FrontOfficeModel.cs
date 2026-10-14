namespace EduCoreDataAccessLayer.Models.ERP
{
    /// <summary>
    /// One write to the front office (core.sp_front_office_manage). The same fields serve
    /// a visitor, a call and a complaint; each operation reads the ones it needs.
    /// </summary>
    public class FrontOfficeEntry
    {
        public int?    Id        { get; set; }
        public string? Name      { get; set; }
        public string? Mobile    { get; set; }
        /// <summary>Visitor / call purpose, or the complaint category.</summary>
        public string? Purpose   { get; set; }
        /// <summary>Visitor: whom to meet. Complaint: assigned to.</summary>
        public string? ToMeet    { get; set; }
        public int?    Persons   { get; set; }
        public string? IdProof   { get; set; }
        /// <summary>Visitor / call note, complaint description, or the status note.</summary>
        public string? Note      { get; set; }
        /// <summary>Call: Incoming / Outgoing. Complaint: Parent / Student / Staff / Other.</summary>
        public string? Direction { get; set; }
        /// <summary>yyyy-MM-dd</summary>
        public string? FollowUp  { get; set; }
        public string? Student   { get; set; }
        public string? Status    { get; set; }
    }
}
