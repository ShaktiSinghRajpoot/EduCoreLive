using EduCoreDataAccessLayer.Models.ERP;

namespace EduCoreDataAccessLayer.Services.Contract.ERP
{
    /// <summary>Bonafide / Character certificates and report-card extras (report_card_certificates.sql).</summary>
    public interface ICertificateService
    {
        /// <summary>Current and former students matching name / adm. no / father / mobile.</summary>
        Task<List<CertificateStudentHit>> SearchStudentsAsync(string q, int tenantId, int schoolId, int actionUserId);

        Task<(bool Success, string Message, int CertId)> IssueAsync(int studentId, string type, string? purpose, string? conduct,
                                                                    string? remarks, int tenantId, int schoolId, int actionUserId);

        Task<Certificate?> GetAsync(int certId, int tenantId, int schoolId, int actionUserId);

        Task<List<Certificate>> GetListAsync(string? type, string? search, int tenantId, int schoolId, int actionUserId);

        Task<(bool Success, string Message)> VoidAsync(int certId, string reason, int tenantId, int schoolId, int actionUserId);

        /// <summary>Mother's name and the session's attendance for each student, keyed by student id.</summary>
        Task<Dictionary<int, ReportCardExtra>> GetReportCardExtrasAsync(IEnumerable<int> studentIds, string academicYear,
                                                                        int tenantId, int schoolId, int actionUserId);
    }
}
